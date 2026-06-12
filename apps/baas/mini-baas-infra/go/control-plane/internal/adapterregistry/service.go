package adapterregistry

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/sync/singleflight"
)

// ErrNotFound is returned when a tenant database row does not exist.
var ErrNotFound = errors.New("database not found")

// ErrConflict is returned on the (tenant_id, name) unique violation.
var ErrConflict = errors.New("database already registered")

// ErrEngineNotInPackage is returned when a tenant tries to register a mount for
// an engine its package tier does not include (Phase 4).
var ErrEngineNotInPackage = errors.New("engine not included in tenant package")

// ErrMountQuotaExceeded is returned when a tenant is already at its package's
// max_mounts cap (Phase 4).
var ErrMountQuotaExceeded = errors.New("tenant has reached its package mount quota")

// Service implements the adapter-registry control-plane logic.
type Service struct {
	db   *shared.Postgres
	enc  *Encryptor
	log  *slog.Logger
	pkgs *packages.Manifest
	// enforce gates package tiering (engine allowlist + mount quota +
	// capability_overrides on /connect). Defaults OFF (opt-in via
	// PACKAGE_ENFORCEMENT=1) so enabling tiering NEVER retroactively gates
	// existing `free` tenants — the shadow→cutover discipline: the capability
	// ships dormant (parity), the operator turns it on once tenant plans are
	// set. When OFF, /connect emits no mask and registration gates nothing.
	enforce bool
	// connCache short-circuits the per-record scrypt KDF (N=16384, ~50-100ms
	// CPU) in Decrypt on the hot /connect path: under 200-tenant fan-out the
	// per-call KDF convoyed the service to 100s+ responses (m39). Keyed by db
	// id and validated against the ciphertext auth tag, which changes whenever
	// the stored payload changes — re-registration self-invalidates, deletes
	// 404 before the cache is consulted. The tenant-ownership check and the
	// health stamp still run per call; only the KDF+decrypt is skipped.
	connCache sync.Map // db id (string) → connCacheEntry
	// sf coalesces concurrent cache misses for the SAME mount into one
	// Decrypt: a cold fan-out otherwise stampedes N identical scrypt runs
	// before the first can populate the cache. Concurrency across DISTINCT
	// mounts is already bounded inside the Encryptor (crypto.go scryptSlots,
	// SCRYPT_MAX_CONCURRENT) — the memory bound that stopped the 2026-06-11
	// bulk-registration OOM loop.
	sf singleflight.Group
}

// connCacheEntry pins the decrypted DSN to the exact ciphertext (auth tag)
// it came from.
type connCacheEntry struct {
	tag  string
	conn string
}

// NewService wires the store dependencies. The package manifest is loaded once
// (embedded, so this never touches the filesystem); a manifest-load failure is
// logged and tiering degrades to OFF (fail-open to parity, never fail-closed on
// a config bug — a broken manifest must not take the data path down).
func NewService(db *shared.Postgres, enc *Encryptor, log *slog.Logger) *Service {
	s := &Service{db: db, enc: enc, log: log, enforce: os.Getenv("PACKAGE_ENFORCEMENT") == "1"}
	m, err := packages.Load()
	if err != nil {
		log.Warn("package manifest load failed; tiering disabled", "error", err)
		s.enforce = false
		return s
	}
	s.pkgs = m
	return s
}

// packageForTenant resolves a tenant slug to its (name, package) via the
// tenant's `plan` column. Returns ok=false when tiering is disabled or the
// manifest is unavailable, so callers cleanly skip enforcement (parity).
func (s *Service) packageForTenant(ctx context.Context, tenantSlug string) (string, packages.Package, bool) {
	if !s.enforce || s.pkgs == nil {
		return "", packages.Package{}, false
	}
	var plan string
	rows, err := s.db.AdminQuery(ctx, `SELECT plan FROM public.tenants WHERE slug = $1`, tenantSlug)
	if err == nil {
		defer rows.Close()
		if rows.Next() {
			_ = rows.Scan(&plan)
		}
	} else {
		s.log.Warn("package lookup failed; treating as default tier", "tenant", tenantSlug, "error", err)
	}
	name, pkg := s.pkgs.For(plan)
	return name, pkg, true
}

// EnsureSchema creates public.tenant_databases idempotently. The live schema
// has tenant_id as TEXT (set by migration 005 + 030 in the TS days); we
// preserve that here since changing column type would require a destructive
// migration. The fresh-install shape uses TEXT to stay aligned.
//
// Tenant policy: M12 retired the pre-existing 'tenant_isolation' policy that
// compared `tenant_id` against `auth.current_user_id()` (i.e. treated every
// user as their own tenant). The corrected policy uses
// `auth.current_tenant_id()` and is named `tenant_databases_tenant_isolation`
// to avoid collision with the legacy name. We drop the old name on upgrade.
func (s *Service) EnsureSchema(ctx context.Context) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS public.tenant_databases (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       TEXT NOT NULL,
  engine          TEXT NOT NULL CHECK (engine IN ('postgresql','cockroachdb','mongodb','mysql','mariadb','redis','sqlite','mssql','http','jdbc','cassandra','neo4j','elasticsearch','qdrant','influx')),
  name            TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
  connection_enc  BYTEA NOT NULL,
  connection_iv   BYTEA NOT NULL,
  connection_tag  BYTEA NOT NULL,
  connection_salt BYTEA,
  created_at      TIMESTAMPTZ DEFAULT now(),
  last_healthy_at TIMESTAMPTZ,
  isolation       TEXT NOT NULL DEFAULT 'shared_rls' CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned')),
  UNIQUE (tenant_id, name)
);
-- Additive for pre-existing tables (the CHECK above only applies to fresh installs).
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS isolation TEXT NOT NULL DEFAULT 'shared_rls';
-- Idempotently widen the fresh-install CHECK on upgraded databases so
-- tenant_owned mounts register (older installs baked the 3-value list).
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_isolation_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_isolation_check
  CHECK (isolation IN ('shared_rls','schema_per_tenant','db_per_tenant','tenant_owned'));
-- Idempotently widen the engine CHECK so newer engine ids (mariadb,
-- cockroachdb, mssql) register on upgraded databases (older installs baked a
-- narrower engine list). The broad set stays at the DB layer; control-plane
-- allowedEngines is the honest ACCEPT gate (only engines with a live Rust pool).
ALTER TABLE public.tenant_databases DROP CONSTRAINT IF EXISTS tenant_databases_engine_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_engine_check
  CHECK (engine IN ('postgresql','cockroachdb','mongodb','mysql','mariadb','redis','sqlite','mssql','http','jdbc','cassandra','neo4j','elasticsearch','qdrant','influx'));
ALTER TABLE public.tenant_databases ENABLE ROW LEVEL SECURITY;
-- Retire the pre-M12 broken policy on upgrade.
DROP POLICY IF EXISTS tenant_isolation ON public.tenant_databases;
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'tenant_databases' AND policyname = 'tenant_databases_tenant_isolation'
  ) THEN
    CREATE POLICY tenant_databases_tenant_isolation ON public.tenant_databases
      FOR ALL USING (tenant_id::text = auth.current_tenant_id()::text)
      WITH CHECK (tenant_id::text = auth.current_tenant_id()::text);
  END IF;
END $$;`
	return s.db.AdminExec(ctx, ddl)
}

// Register encrypts the connection string and inserts the row under tenant RLS.
func (s *Service) Register(ctx context.Context, userID string, req RegisterDatabaseRequest) (RegisterResult, error) {
	payload, err := s.enc.Encrypt(req.ConnectionString)
	if err != nil {
		return RegisterResult{}, err
	}

	isolation := req.Isolation
	if isolation == "" {
		isolation = "shared_rls"
	}

	// Phase 4 tiering: the engine must be in the tenant's package, and the
	// tenant must be under its package's max_mounts cap. A no-op when
	// PACKAGE_ENFORCEMENT=0 / manifest unavailable.
	_, pkg, tiered := s.packageForTenant(ctx, userID)
	if tiered && !pkg.AllowsEngine(req.Engine) {
		return RegisterResult{}, fmt.Errorf("%w: %q (package allows %v)", ErrEngineNotInPackage, req.Engine, pkg.Engines)
	}

	var out RegisterResult
	err = s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// Mount-quota check INSIDE the tx so the count is consistent with the
		// insert (no TOCTOU under concurrent registrations).
		if tiered && pkg.PoolPolicy.MaxMounts > 0 {
			var count int
			if err := tx.QueryRow(ctx,
				`SELECT count(*) FROM public.tenant_databases WHERE tenant_id = $1`, userID).Scan(&count); err != nil {
				return err
			}
			if count >= pkg.PoolPolicy.MaxMounts {
				return ErrMountQuotaExceeded
			}
		}
		row := tx.QueryRow(ctx,
			`INSERT INTO public.tenant_databases
			   (tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt, isolation)
			 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			 RETURNING id, engine, name, created_at::text`,
			userID, req.Engine, req.Name,
			payload.Encrypted, payload.IV, payload.Tag, payload.Salt, isolation,
		)
		return row.Scan(&out.ID, &out.Engine, &out.Name, &out.CreatedAt)
	})
	if errors.Is(err, ErrMountQuotaExceeded) {
		return RegisterResult{}, err
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return RegisterResult{}, ErrConflict
		}
		return RegisterResult{}, err
	}
	return out, nil
}

// List returns tenant database metadata, newest first.
func (s *Service) List(ctx context.Context, userID string) ([]TenantDatabase, error) {
	out := make([]TenantDatabase, 0)
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx,
			`SELECT id::text, tenant_id::text, engine, name, created_at::text, last_healthy_at::text
			   FROM public.tenant_databases
			  ORDER BY created_at DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var d TenantDatabase
			if err := rows.Scan(&d.ID, &d.TenantID, &d.Engine, &d.Name, &d.CreatedAt, &d.LastHealthyAt); err != nil {
				return err
			}
			out = append(out, d)
		}
		return rows.Err()
	})
	return out, err
}

// FindOne returns a single tenant database metadata row.
func (s *Service) FindOne(ctx context.Context, userID, id string) (TenantDatabase, error) {
	var d TenantDatabase
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx,
			`SELECT id::text, tenant_id::text, engine, name, created_at::text, last_healthy_at::text
			   FROM public.tenant_databases WHERE id = $1`, id)
		err := row.Scan(&d.ID, &d.TenantID, &d.Engine, &d.Name, &d.CreatedAt, &d.LastHealthyAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return d, err
}

// GetConnection decrypts and returns the connection string for the data plane.
func (s *Service) GetConnection(ctx context.Context, userID, id string) (ConnectionResult, error) {
	var (
		engine    string
		isolation string
		payload   EncryptedPayload
	)
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		// EXPLICIT tenant scope (not just the RLS policy): the control-plane DB
		// role owns/bypasses RLS on tenant_databases, so without `AND
		// tenant_id = $2` a mount's UUID would be a bearer capability — ANY
		// valid tenant key + the dbId would resolve (and read) ANOTHER
		// tenant's mount. The whole tenant_owned safety model rests on this
		// caller==owner check at resolve time. `userID` is the caller tenant
		// the query-router forwards as X-Tenant-Id.
		row := tx.QueryRow(ctx,
			`SELECT engine, isolation, connection_enc, connection_iv, connection_tag, connection_salt
			   FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
		err := row.Scan(&engine, &isolation, &payload.Encrypted, &payload.IV, &payload.Tag, &payload.Salt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		// fire-and-forget health timestamp, same intent as the Node service
		_, _ = tx.Exec(ctx, `UPDATE public.tenant_databases SET last_healthy_at = now() WHERE id = $1 AND tenant_id = $2`, id, userID)
		return nil
	})
	if err != nil {
		return ConnectionResult{}, err
	}

	// scrypt-decrypt only when the ciphertext changed since the last call (the
	// auth tag is a cryptographic digest of payload+key — equal tag ⇒ equal
	// plaintext). Concurrent misses for one mount coalesce (sf) and distinct
	// cold mounts queue on kdfSem. See connCache.
	var conn string
	tag := string(payload.Tag)
	if v, ok := s.connCache.Load(id); ok {
		if e, ok := v.(connCacheEntry); ok && e.tag == tag {
			conn = e.conn
		}
	}
	if conn == "" {
		v, derr, _ := s.sf.Do(id+"\x00"+tag, func() (any, error) {
			if v, ok := s.connCache.Load(id); ok {
				if e, ok := v.(connCacheEntry); ok && e.tag == tag {
					return e.conn, nil
				}
			}
			c, err := s.enc.Decrypt(payload)
			if err != nil {
				return nil, err
			}
			s.connCache.Store(id, connCacheEntry{tag: tag, conn: c})
			return c, nil
		})
		if derr != nil {
			return ConnectionResult{}, derr
		}
		conn, _ = v.(string)
	}
	result := ConnectionResult{Engine: engine, ConnectionString: conn, Isolation: isolation}
	// Phase 4 tiering: stamp the tenant's package tier mask so the data plane
	// enforces capability gating (403) + rate limiting (429). Resolved from the
	// tenant's `plan`; a no-op when PACKAGE_ENFORCEMENT=0.
	if name, pkg, ok := s.packageForTenant(ctx, userID); ok {
		result.Package = name
		result.CapabilityOverrides = pkg.CapabilityOverrides()
	}
	return result, nil
}

// Remove deletes a database by id (admin scope, bypasses RLS).
func (s *Service) Remove(ctx context.Context, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 RETURNING id`, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	return nil
}
