// Package main boots the tenant-control service.
//
// Owns:
//
//	POST /v1/tenants              create a tenant row
//	GET  /v1/tenants              list tenants (admin)
//	GET  /v1/tenants/:id          fetch (self or admin)
//	PATCH/DELETE /v1/tenants/:id  admin
//	POST /v1/tenants/:id/bootstrap   tenant + default role + first key
//	POST /v1/tenants/:id/keys     issue API key
//	GET  /v1/tenants/:id/keys     list keys (redacted)
//	DELETE /v1/tenants/:id/keys/:keyId   revoke
//	POST /v1/keys/verify          gateway-internal: cleartext key -> identity
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/metering"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

func main() {
	log := shared.NewLogger("tenant-control")

	cfg, err := shared.LoadConfig("TENANT_CONTROL")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}

	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	db, err := shared.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	svc := tenants.NewService(db, log)
	if err := svc.EnsureSchema(ctx); err != nil {
		log.Error("schema check failed", "err", err)
		os.Exit(1)
	}

	// Optional adapter-registry client — enables POST /v1/provision to register
	// a tenant's data mounts as part of one declarative reconcile call.
	if arURL := os.Getenv("ADAPTER_REGISTRY_URL"); arURL != "" {
		svc.SetAdapterRegistry(tenants.NewAdapterRegistry(arURL, cfg.ServiceToken))
		log.Info("adapter-registry client enabled", "url", arURL)
	} else {
		log.Warn("ADAPTER_REGISTRY_URL not set — /v1/provision will not register mounts")
	}

	// Optional Rust data-plane client — lets /v1/provision create the per-tenant
	// schema for schema_per_tenant mounts (via /v1/admin/migrate).
	if dpURL := os.Getenv("RUST_DATA_PLANE_URL"); dpURL != "" {
		svc.SetDataPlane(tenants.NewDataPlane(dpURL, cfg.ServiceToken))
		log.Info("data-plane client enabled", "url", dpURL)
	}

	// PermissionEngine seam: direct-SQL ABAC against the same Postgres, with an
	// optional HTTP /permissions/decide self-verify hook (PERMISSION_ENGINE_URL).
	// One role implementation, shared by Bootstrap's seedDefaultRole AND the
	// declarative reconciler below.
	permURL := os.Getenv("PERMISSION_ENGINE_URL")
	perm := provision.NewSQLBackend(db, permURL, cfg.ServiceToken)
	svc.SetPermissionEngine(perm)
	if permURL != "" {
		log.Info("permission-engine self-verify enabled", "url", permURL)
	} else {
		log.Warn("PERMISSION_ENGINE_URL not set — provision Decide() self-verify disabled (role/policy seeding still works via SQL)")
	}

	// Provisioning brain: the declarative reconciler wiring the tenant service,
	// the ABAC seam, and the (optional) mount + schema clients. Route ownership
	// stays in tenants.Mount; this is just the engine it delegates to.
	reconciler := svc.BuildReconciler(perm, log)

	// Optional GoTrue JWT verifier — enables POST /v1/tenants/me/bootstrap.
	// If neither env var is set, that endpoint returns 501.
	jwtSecret := envFirst("GOTRUE_JWT_SECRET", "JWT_SECRET")
	var jwtVerifier *tenants.JWTVerifier
	if jwtSecret != "" {
		v, err := tenants.NewJWTVerifier(jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"))
		if err != nil {
			log.Error("jwt verifier init failed", "err", err)
			os.Exit(1)
		}
		jwtVerifier = v
		log.Info("jwt verifier enabled", "issuer", os.Getenv("GOTRUE_JWT_ISSUER"))
	} else {
		log.Warn("no GOTRUE_JWT_SECRET/JWT_SECRET set — /v1/tenants/me/bootstrap disabled")
	}

	mux := shared.NewRouter("tenant-control", db)
	tenants.Mount(mux, svc, cfg.ServiceToken, jwtVerifier, reconciler)

	// Metering read-back API (Track-B B1c): GET /v1/tenants/{id}/usage. Purely
	// additive read over public.tenant_usage (migration 040), same admin/self
	// auth + tenant-scoping as GET /v1/tenants/{id}. No flag gates the READ path
	// — when metering is OFF the table is empty and it returns empty aggregates,
	// so this route changes no existing path (that IS the parity story).
	metering.Mount(mux, db, cfg.ServiceToken)

	// Tenant self-service API (Track-B B4a): /v1/tenants/me* — a caller
	// authenticated AS a tenant (API key OR GoTrue JWT) manages its OWN tenant
	// (read tenant+entitlements, read usage, list/issue/revoke keys, change plan).
	// There is no path id, so cross-tenant access is impossible by construction.
	//
	// FLAG-GATED OFF = PARITY: the /me routes are mounted ONLY when
	// TENANT_SELFSERVE_ENABLED is truthy. When OFF (the default) MountSelfServe is
	// never called, so those routes do not exist and a request 404s — byte-
	// identical to today. A malformed manifest fails fast (tiering is a security
	// boundary) but only along this opt-in path; the baseline is untouched.
	if envBool("TENANT_SELFSERVE_ENABLED") {
		manifest, err := packages.Load()
		if err != nil {
			log.Error("tenant self-serve: package manifest load failed", "err", err)
			os.Exit(1)
		}
		tenants.MountSelfServe(mux, svc, jwtVerifier, manifest, envBool("BILLING_ENABLED"))
		log.Info("tenant self-service API enabled (/v1/tenants/me*)", "billing", envBool("BILLING_ENABLED"))
	} else {
		log.Info("tenant self-service API disabled (TENANT_SELFSERVE_ENABLED off) — /v1/tenants/me* not mounted")
	}

	srv := &http.Server{
		Addr:              cfg.ListenAddr(),
		Handler:           shared.WithMiddleware(mux, log),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	log.Info("stopped")
}

func envFirst(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return ""
}

// envBool reads a truthy env flag (mirrors metering.envBool). Default (unset or
// anything not truthy) is false — so a flag-gated path stays OFF unless
// explicitly enabled, which is the parity default.
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}

func healthcheck(cfg shared.Config) int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + cfg.Port + "/health/live")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
