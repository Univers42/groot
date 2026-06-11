package adapterregistry

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

const msgNotFound = "database not found"

// routes binds the service + service token for handler methods.
type routes struct {
	svc          *Service
	serviceToken string
}

// Mount registers adapter-registry routes onto the shared mux.
//
// Identity model for the shadow phase: the trust boundary (Kong / gateway)
// injects the authenticated tenant as the `X-User-Id` header. The internal
// `/connect` and delete routes additionally require the service token,
// mirroring the legacy ServiceTokenGuard / RolesGuard.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /databases", rt.register)
	mux.HandleFunc("GET /databases", rt.list)
	mux.HandleFunc("GET /databases/{id}", rt.findOne)
	mux.HandleFunc("GET /databases/{id}/connect", rt.connect)
	mux.HandleFunc("DELETE /databases/{id}", rt.remove)
}

func (rt *routes) register(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	var req RegisterDatabaseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	res, err := rt.svc.Register(r.Context(), userID, req)
	if errors.Is(err, ErrConflict) {
		shared.WriteError(w, http.StatusConflict, "conflict", "database \""+req.Name+"\" already registered")
		return
	}
	// Phase 4 tiering: an engine outside the tenant's package, or a mount past
	// its quota, is an authorization/quota denial (403) — upgrade the package.
	if errors.Is(err, ErrEngineNotInPackage) {
		shared.WriteError(w, http.StatusForbidden, "engine_not_in_package", err.Error())
		return
	}
	if errors.Is(err, ErrMountQuotaExceeded) {
		shared.WriteError(w, http.StatusForbidden, "mount_quota_exceeded", err.Error())
		return
	}
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, res)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.List(r.Context(), userID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) findOne(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	db, err := rt.svc.FindOne(r.Context(), userID, r.PathValue("id"))
	if rt.handleLookupError(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, db)
}

func (rt *routes) connect(w http.ResponseWriter, r *http.Request) {
	if !validServiceToken(r, rt.serviceToken) {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	userID, ok := requireUser(w, r)
	if !ok {
		return
	}
	conn, err := rt.svc.GetConnection(r.Context(), userID, r.PathValue("id"))
	if rt.handleLookupError(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, conn)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	if !validServiceToken(r, rt.serviceToken) {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	if rt.handleLookupError(w, rt.svc.Remove(r.Context(), r.PathValue("id"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

// handleLookupError writes the response for not-found / internal errors and
// reports whether the caller should stop. Returns false on success (err == nil).
func (rt *routes) handleLookupError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", msgNotFound)
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}

func requireUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	// Header precedence (post-M11 signed-envelope migration):
	//   1. X-Baas-User-Id   — signed envelope user id
	//   2. X-Baas-Tenant-Id — signed envelope tenant id (rows are keyed by tenant)
	//   3. X-User-Id        — legacy raw header (compat mode only)
	//   4. X-Tenant-Id      — legacy raw tenant header
	// The TS service did full HMAC verification on the X-Baas-* headers; the
	// Go service currently TRUSTS them (the data plane and adapter-registry
	// sit on a private docker network, and write paths additionally require
	// X-Service-Token). Adding HMAC verification here is a follow-up slice.
	for _, h := range []string{"X-Baas-User-Id", "X-Baas-Tenant-Id", "X-User-Id", "X-Tenant-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing user/tenant header (X-Baas-User-Id, X-Baas-Tenant-Id, X-User-Id or X-Tenant-Id)")
	return "", false
}

func validServiceToken(r *http.Request, expected string) bool {
	// Constant-time compare (timing-leak fix) — see shared.SecureCompare.
	return shared.VerifyServiceRequest(r, expected)
}
