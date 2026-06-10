package adapterregistry

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrNotFound is returned when a tenant database row does not exist.
var ErrNotFound = errors.New("database not found")

// ErrConflict is returned on the (tenant_id, name) unique violation.
var ErrConflict = errors.New("database already registered")

// Service implements the adapter-registry control-plane logic.
type Service struct {
	db  *shared.Postgres
	enc *Encryptor
	log *slog.Logger
}

// NewService wires the store dependencies.
func NewService(db *shared.Postgres, enc *Encryptor, log *slog.Logger) *Service {
	return &Service{db: db, enc: enc, log: log}
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

	var out RegisterResult
	err = s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
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

	conn, err := s.enc.Decrypt(payload)
	if err != nil {
		return ConnectionResult{}, err
	}
	return ConnectionResult{Engine: engine, ConnectionString: conn, Isolation: isolation}, nil
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
