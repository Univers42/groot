package shared

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// dsnRe matches a connection-string-shaped substring (scheme://[creds@]host…),
// e.g. postgres://user:pass@db:5432/app or redis://:secret@cache:6379. Used to
// scrub DSNs that an upstream service may echo back inside an error body before
// the message is surfaced to a caller / log.
var dsnRe = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'\\]+`)

// RedactDSN replaces any DSN-shaped substring with a placeholder so credentials
// reflected in an upstream error body never leak into a ResourceResult.Error or
// a log line.
func RedactDSN(s string) string {
	return dsnRe.ReplaceAllString(s, "[redacted-dsn]")
}

// NewRouter builds a base mux with liveness/readiness probes and a Prometheus
// /metrics endpoint. The metrics sink is process-global (one binary == one
// service), so no service-specific wiring is needed at the call site.
func NewRouter(service string, db *Postgres) *http.ServeMux {
	procMetrics.setService(service)
	mux := http.NewServeMux()

	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		procMetrics.writeProm(w)
	})

	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": service})
	})

	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(r.Context()); err != nil {
			WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "degraded", "error": "db_unreachable"})
			return
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ready", "service": service})
	})

	return mux
}

// WriteJSON serializes v as a JSON response with the given status code.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError emits a structured JSON error.
func WriteError(w http.ResponseWriter, status int, code, message string) {
	WriteJSON(w, status, map[string]any{"error": code, "message": message, "statusCode": status})
}

// WithMiddleware wraps a handler with panic recovery, cross-plane correlation
// (X-Request-ID + traceparent), and access logging. The correlation id comes
// from Kong at the edge; for direct calls a fallback id is minted so every
// request is traceable. Both values are placed on the request context (so
// downstream outbound calls can forward them via PropagateHeaders) and the
// request id is echoed back to the caller.
func WithMiddleware(next http.Handler, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}

		requestID := r.Header.Get(HeaderRequestID)
		if requestID == "" {
			requestID = newRequestID()
		}
		traceparent := r.Header.Get(HeaderTraceparent)
		sw.Header().Set(HeaderRequestID, requestID)
		r = r.WithContext(WithCorrelation(r.Context(), requestID, traceparent))

		defer func() {
			if rec := recover(); rec != nil {
				log.Error("panic recovered", "err", rec, "path", r.URL.Path, "request_id", requestID)
				WriteError(sw, http.StatusInternalServerError, "internal_error", "unexpected error")
			}
			// Record request metrics, but skip the probe/scrape paths so the
			// counters reflect real API traffic rather than health-check noise.
			if !strings.HasPrefix(r.URL.Path, "/health") && r.URL.Path != "/metrics" {
				procMetrics.observe(r.Method, sw.status, time.Since(start))
			}
			log.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", sw.status,
				"ms", time.Since(start).Milliseconds(),
				"request_id", requestID,
				"traceparent", traceparent,
			)
		}()

		next.ServeHTTP(sw, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}
