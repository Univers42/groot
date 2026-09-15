# M4 — Production-grade observability

**Targets:** dimensions **e** (security & observability), **g** (auditability).
**Gate:** `make baas-verify-m4` returns `0`.
**Estimated effort:** 2 days.
**Risk:** low — additive only, no existing service modified.
**Depends on:** M1 (correlation-ID + audit_log), M3 (coherent system to observe).

## Why

The wiki already mentions Prometheus / Grafana / Loki, but the BaaS compose has none of them. Without `/metrics`, traces, and a log pipeline, dimensions **e** and **g** cannot honestly cross 7/10.

## Deliverables

### 1. Observability stack in compose

Add under `apps/baas/mini-baas-infra/docker/services/`:

| Service | Image | Role |
|---|---|---|
| `prometheus` | `prom/prometheus:v2.55` | Metric scrape + storage |
| `grafana` | `grafana/grafana:11.3` | Dashboards |
| `loki` | `grafana/loki:3.2` | Log aggregation |
| `promtail` | `grafana/promtail:3.2` | Docker log shipper → Loki |
| `tempo` | `grafana/tempo:2.6` | Trace storage |
| `otel-collector` | `otel/opentelemetry-collector-contrib:0.110` | Receives OTLP → Tempo/Prometheus/Loki |

All in a new compose profile `observability` with `HEALTHCHECK`, non-root user, pinned digests.

### 2. `/metrics` on every NestJS app

Add `@willsoto/nestjs-prometheus` to the workspace. In every `main.ts`:

```ts
import { PrometheusModule } from '@willsoto/nestjs-prometheus';
// ...
PrometheusModule.register({
  defaultMetrics: { enabled: true },
  path: '/metrics',
});
```

Expose RED metrics (Rate, Errors, Duration) via a global interceptor in `libs/common/src/interceptors/metrics.interceptor.ts`.

Prometheus scrape config (`docker/services/prometheus/conf/prometheus.yml`) statically lists the 9 services.

### 3. OpenTelemetry SDK

New file `src/libs/common/src/tracing/otel.bootstrap.ts`:

```ts
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';

export function startOtel(serviceName: string) {
  const sdk = new NodeSDK({
    serviceName,
    traceExporter: new OTLPTraceExporter({
      url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://otel-collector:4318/v1/traces',
    }),
    instrumentations: [getNodeAutoInstrumentations()],
  });
  sdk.start();
}
```

Call `startOtel('<service-name>')` at the top of every `main.ts` *before* `NestFactory.create`.

Propagate `X-Request-ID` as `traceparent` so the correlation-ID from M1 becomes the trace ID.

### 4. Log pipeline

- Set every NestJS app's logger to JSON output (`pino` or NestJS's `LoggerService` with JSON formatter).
- `log-service` (currently a memory buffer) writes batches to Loki via the HTTP push API.
- `promtail` ships Docker container stdout/stderr to Loki as a fallback.

### 5. Default dashboards

Provision in `docker/services/grafana/provisioning/dashboards/`:

- **BaaS overview**: RED per service, error rate, p95 latency.
- **Auth flow**: GoTrue success/failure, JWT verification latency.
- **Federation**: query-router op rate per engine, adapter-registry lookups, Trino query duration.
- **Coherence (M3)**: outbox lag, dead events, idempotency hit rate.

### 6. Alerting

`prometheus/conf/alerts.yml` with at minimum:

- `service_down` (no scrape for 1m)
- `error_rate_high` (5xx > 5% for 5m)
- `outbox_lag_high` (pending events > 1000)
- `audit_log_write_failed`

## Make gate

New file `scripts/verify/m4-observability.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[M4] observability stack up"
for svc in prometheus grafana loki promtail tempo otel-collector; do
  curl -fsS "http://localhost:$(bash scripts/resolve-ports.sh $svc)/-/healthy" >/dev/null 2>&1 \
    || curl -fsS "http://localhost:$(bash scripts/resolve-ports.sh $svc)/ready" >/dev/null 2>&1 \
    || curl -fsS "http://localhost:$(bash scripts/resolve-ports.sh $svc)/health" >/dev/null \
    || { echo "[M4] FAIL: $svc not healthy"; exit 1; }
done

echo "[M4] all NestJS apps expose /metrics with default counters"
for svc in query-router mongo-api storage-router permission-engine gdpr-service \
           session-service log-service newsletter-service schema-service; do
  port=$(bash scripts/resolve-ports.sh "$svc")
  curl -fsS "http://localhost:${port}/metrics" | grep -q '^process_cpu_seconds_total ' \
    || { echo "[M4] FAIL: $svc /metrics missing default counters"; exit 1; }
done

echo "[M4] prometheus scraping all 9 services"
up=$(curl -fsS "http://localhost:${PROM_PORT}/api/v1/query?query=up" \
  | jq '[.data.result[] | select(.value[1] == "1")] | length')
[[ "$up" -ge 9 ]] || { echo "[M4] FAIL: only $up targets up"; exit 1; }

echo "[M4] end-to-end trace visible in Tempo"
req_id="$(uuidgen)"
curl -fsS -X POST "https://localhost:8443/query/${DB_ID}/mock_orders" \
  -H "Authorization: Bearer ${USER_JWT}" \
  -H "X-Request-ID: ${req_id}" \
  --data '{"op":"insert","data":{"name":"m4-trace"}}' >/dev/null

sleep 2
trace=$(curl -fsS "http://localhost:${TEMPO_PORT}/api/search?tags=request_id=${req_id}" \
  | jq -r '.traces[0].traceID // empty')
[[ -n "$trace" ]] || { echo "[M4] FAIL: trace not found in Tempo"; exit 1; }

echo "[M4] logs reach Loki"
logs=$(curl -fsS -G "http://localhost:${LOKI_PORT}/loki/api/v1/query" \
  --data-urlencode "query={service=\"query-router\"} |= \"${req_id}\"" \
  | jq '.data.result | length')
[[ "$logs" -ge 1 ]] || { echo "[M4] FAIL: no log line with request_id in Loki"; exit 1; }

echo "[M4] OK"
```

## Done when

- All 6 observability services are healthy and reachable.
- Every NestJS app exposes `/metrics` and is scraped successfully.
- A single HTTP request produces correlated artefacts in Tempo (trace), Prometheus (counter increment), Loki (log lines), and `audit_log` (row).
- At least 4 dashboards provisioned in Grafana.
- `make baas-verify-m4` exits `0`.
