package shared

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// procMetrics is the process-wide metrics sink. Each control-plane binary runs
// as its own OS process, so a package-level singleton is naturally scoped to a
// single service — the same pattern client_golang's default registry uses.
//
// Keeping this dependency-free (no client_golang) is deliberate: the control
// plane's value proposition is tiny, fast-starting static binaries, and the
// three daemons only need request counts + a mean-latency gauge to be visible
// to Prometheus. See wiki/05-orchestration-observability-roadmap.md §2 (G7).
var procMetrics = &metrics{start: time.Now()}

type metrics struct {
	service  string
	start    time.Time
	counts   sync.Map // key "METHOD:Nxx" -> *int64
	sumNs    int64    // cumulative request duration, for a mean gauge
	sumCount int64
}

func (m *metrics) setService(name string) { m.service = name }

// observe records one finished request. method/status come from the middleware.
func (m *metrics) observe(method string, status int, d time.Duration) {
	key := method + ":" + fmt.Sprintf("%dxx", status/100)
	ctr, _ := m.counts.LoadOrStore(key, new(int64))
	atomic.AddInt64(ctr.(*int64), 1)
	atomic.AddInt64(&m.sumNs, d.Nanoseconds())
	atomic.AddInt64(&m.sumCount, 1)
}

// writeProm emits the Prometheus text exposition format (v0.0.4).
func (m *metrics) writeProm(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	svc := m.service

	fmt.Fprintf(w, "# HELP baas_service_up 1 while the service is serving\n")
	fmt.Fprintf(w, "# TYPE baas_service_up gauge\n")
	fmt.Fprintf(w, "baas_service_up{service=%q} 1\n", svc)

	fmt.Fprintf(w, "# HELP baas_uptime_seconds Seconds since process start\n")
	fmt.Fprintf(w, "# TYPE baas_uptime_seconds gauge\n")
	fmt.Fprintf(w, "baas_uptime_seconds{service=%q} %.0f\n", svc, time.Since(m.start).Seconds())

	fmt.Fprintf(w, "# HELP baas_http_requests_total HTTP requests by method and status class\n")
	fmt.Fprintf(w, "# TYPE baas_http_requests_total counter\n")
	m.counts.Range(func(k, v any) bool {
		parts := strings.SplitN(k.(string), ":", 2)
		fmt.Fprintf(w, "baas_http_requests_total{service=%q,method=%q,status=%q} %d\n",
			svc, parts[0], parts[1], atomic.LoadInt64(v.(*int64)))
		return true
	})

	n := atomic.LoadInt64(&m.sumCount)
	avg := 0.0
	if n > 0 {
		avg = float64(atomic.LoadInt64(&m.sumNs)) / float64(n) / 1e6
	}
	fmt.Fprintf(w, "# HELP baas_http_request_duration_ms_avg Mean request duration in milliseconds\n")
	fmt.Fprintf(w, "# TYPE baas_http_request_duration_ms_avg gauge\n")
	fmt.Fprintf(w, "baas_http_request_duration_ms_avg{service=%q} %.3f\n", svc, avg)
}
