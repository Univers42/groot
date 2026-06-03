# Edge Functions runtime (Deno worker-per-invocation MVP).
#
# Tenants POST TypeScript/JavaScript source to /v1/functions. Code is persisted
# to /data/<tenant_id>/<name>.ts. Invocation spawns a fresh Deno Worker with a
# minimal permission set (no FS, no env, network only to allow-listed hosts).
#
# Limitations (documented honestly in wiki/back/08):
#   - per-invocation worker startup is ~20-40ms (no warm pool yet)
#   - no resource caps beyond Deno's V8 isolate; for hard CPU/RAM caps you need
#     cgroups around a separate child process (planned, not MVP)
#   - no streaming response support (request/response only)
FROM denoland/deno:alpine-2.1.4

ENV FUNCTIONS_HOST=0.0.0.0 \
    FUNCTIONS_PORT=3060 \
    FUNCTIONS_DATA_DIR=/data \
    FUNCTIONS_INVOKE_TIMEOUT_MS=5000

WORKDIR /app
COPY src/ /app/

# Pre-cache deps for offline starts.
RUN deno cache server.ts || true

VOLUME ["/data"]
EXPOSE 3060

HEALTHCHECK --interval=10s --timeout=3s --start-period=8s --retries=5 \
  CMD wget -qO- http://127.0.0.1:${FUNCTIONS_PORT}/health/live || exit 1

ENTRYPOINT ["deno", "run", \
            "--allow-net", "--allow-read", "--allow-write=/data", \
            "--allow-env", "--unstable-worker-options", \
            "/app/server.ts"]
