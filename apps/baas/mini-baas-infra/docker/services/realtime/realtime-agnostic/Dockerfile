# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Dependency layer (cached unless Cargo.toml / Cargo.lock change)
# ─────────────────────────────────────────────────────────────────────────────
FROM rust:1.89-slim-bookworm AS deps
WORKDIR /build

RUN apt-get update && \
    apt-get install -y pkg-config libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy manifests only — this layer is cached as long as deps don't change.
COPY Cargo.toml Cargo.lock ./
COPY crates/realtime-core/Cargo.toml          crates/realtime-core/Cargo.toml
COPY crates/realtime-engine/Cargo.toml        crates/realtime-engine/Cargo.toml
COPY crates/realtime-bus-inprocess/Cargo.toml crates/realtime-bus-inprocess/Cargo.toml
COPY crates/realtime-auth/Cargo.toml          crates/realtime-auth/Cargo.toml
COPY crates/realtime-gateway/Cargo.toml       crates/realtime-gateway/Cargo.toml
COPY crates/realtime-db-postgres/Cargo.toml   crates/realtime-db-postgres/Cargo.toml
COPY crates/realtime-db-mongodb/Cargo.toml    crates/realtime-db-mongodb/Cargo.toml
COPY crates/realtime-server/Cargo.toml        crates/realtime-server/Cargo.toml
COPY crates/realtime-client/Cargo.toml        crates/realtime-client/Cargo.toml
COPY tests/integration/Cargo.toml             tests/integration/Cargo.toml

# Create stub lib.rs / main.rs for every crate so Cargo can resolve the graph.
RUN for dir in \
        crates/realtime-core \
        crates/realtime-engine \
        crates/realtime-bus-inprocess \
        crates/realtime-auth \
        crates/realtime-gateway \
        crates/realtime-db-postgres \
        crates/realtime-db-mongodb \
        crates/realtime-client \
        tests/integration \
    ; do \
        mkdir -p "$dir/src" && echo "pub fn _placeholder() {}" > "$dir/src/lib.rs"; \
    done && \
    mkdir -p crates/realtime-server/src && \
    echo "fn main() {}" > crates/realtime-server/src/main.rs

# Pre-compile all dependencies (the slow step — cached until deps change).
RUN cargo build --release --bin realtime-server 2>&1 | tail -5

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Application build (only re-runs when source code changes)
# ─────────────────────────────────────────────────────────────────────────────
FROM deps AS builder

# Copy real source (invalidates layer only when source actually changes).
COPY crates/ crates/
COPY tests/  tests/

# Touch main.rs to force Cargo to rebuild the binary (not just deps).
RUN touch crates/realtime-server/src/main.rs && \
    cargo build --release --bin realtime-server

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 – Minimal runtime image  (~15 MB stripped binary + libc)
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && \
    apt-get install -y ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -r realtime && useradd -r -g realtime realtime

WORKDIR /app

COPY --from=builder /build/target/release/realtime-server /app/realtime-server

# Default config file — override by mounting your own at this path.
COPY realtime.toml /etc/realtime/realtime.toml

# Default static files (can be overridden via volume mount at runtime).
COPY sandbox/static/ /app/static/

# Drop to non-root.
USER realtime

EXPOSE 4000

# Config file + env-var overrides.  Mount a custom TOML at the same path
# or set individual REALTIME_* env vars to override specific values.
ENV RUST_LOG="info" \
    REALTIME_CONFIG="/etc/realtime/realtime.toml" \
    REALTIME_HOST="0.0.0.0" \
    REALTIME_PORT="4000" \
    REALTIME_STATIC_DIR="/app/static"

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -sf http://localhost:${REALTIME_PORT}/v1/health > /dev/null || exit 1

CMD ["/app/realtime-server"]
