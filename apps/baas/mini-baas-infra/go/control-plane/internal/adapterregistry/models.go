package adapterregistry

import "fmt"

// allowedEngines is the set of engines the control plane will ACCEPT a mount
// for. Honesty rule (Phase 3): this must be exactly the engines the Rust data
// plane can actually SERVE — registering a mount for an engine with no Rust
// pool would create a row that 501s on every query. The previously-accepted
// stubs (jdbc, cassandra, neo4j, elasticsearch, qdrant, influx) are quarantined
// out: they were never served, so accepting them was a lie. sqlite is added
// when its adapter lands. The DB CHECK constraint stays broader (it never
// rejected these), so existing rows are untouched; only NEW registrations of
// an unserved engine are refused here.
var allowedEngines = map[string]bool{
	"postgresql":  true,
	"cockroachdb": true,
	"mysql":       true,
	"mariadb":     true,
	"mongodb":     true,
	"redis":       true,
	"http":        true,
}

// allowedIsolation mirrors the tenant isolation strategies the data plane
// understands (see data-plane-core DatabaseMount.isolation).
// tenant_owned: an external client DB wholly owned by one tenant — the data
// plane skips per-row owner_id scoping (tenant gating still happens at
// key→mount resolution, so a foreign tenant's key never resolves the mount).
var allowedIsolation = map[string]bool{
	"shared_rls": true, "schema_per_tenant": true, "db_per_tenant": true,
	"tenant_owned": true,
}

// RegisterDatabaseRequest is the JSON body for POST /databases.
type RegisterDatabaseRequest struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	// Isolation is optional; empty defaults to "shared_rls" at store time.
	Isolation string `json:"isolation"`
}

// Validate enforces the same constraints as the Node DTO + DB check.
func (r RegisterDatabaseRequest) Validate() error {
	if !allowedEngines[r.Engine] {
		return fmt.Errorf("unsupported engine %q", r.Engine)
	}
	if l := len(r.Name); l < 1 || l > 64 {
		return fmt.Errorf("name must be 1..64 chars")
	}
	if r.ConnectionString == "" {
		return fmt.Errorf("connection_string is required")
	}
	if r.Isolation != "" && !allowedIsolation[r.Isolation] {
		return fmt.Errorf("unsupported isolation %q", r.Isolation)
	}
	return nil
}

// TenantDatabase is the public metadata view (no secret material).
type TenantDatabase struct {
	ID            string  `json:"id"`
	TenantID      string  `json:"tenant_id"`
	Engine        string  `json:"engine"`
	Name          string  `json:"name"`
	CreatedAt     string  `json:"created_at"`
	LastHealthyAt *string `json:"last_healthy_at"`
}

// RegisterResult is returned by POST /databases.
type RegisterResult struct {
	ID        string `json:"id"`
	Engine    string `json:"engine"`
	Name      string `json:"name"`
	CreatedAt string `json:"created_at"`
}

// ConnectionResult is the internal decrypt response for the data plane.
type ConnectionResult struct {
	Engine           string `json:"engine"`
	ConnectionString string `json:"connection_string"`
	// Isolation tells the data plane how to scope this mount (shared_rls |
	// schema_per_tenant | db_per_tenant).
	Isolation string `json:"isolation"`
}
