FROM public.ecr.aws/docker/library/rust:1.89-slim-bookworm AS deps
WORKDIR /build

COPY Cargo.toml ./
COPY crates/data-plane-core/Cargo.toml crates/data-plane-core/Cargo.toml
COPY crates/data-plane-pool/Cargo.toml crates/data-plane-pool/Cargo.toml
COPY crates/data-plane-server/Cargo.toml crates/data-plane-server/Cargo.toml

RUN for dir in crates/data-plane-core crates/data-plane-pool crates/data-plane-server; do \
      mkdir -p "$dir/src"; \
      echo "pub fn placeholder() {}" > "$dir/src/lib.rs"; \
    done && \
    echo "fn main() {}" > crates/data-plane-server/src/main.rs && \
    cargo build --release --bin data-plane-router

FROM deps AS builder
COPY crates/ crates/
RUN touch crates/data-plane-core/src/*.rs crates/data-plane-pool/src/*.rs crates/data-plane-server/src/*.rs && \
    cargo build --release --bin data-plane-router

FROM gcr.io/distroless/cc-debian12:nonroot AS runtime
WORKDIR /app

COPY --from=builder --chown=nonroot:nonroot /build/target/release/data-plane-router /app/data-plane-router

USER nonroot:nonroot
EXPOSE 4011

ENV RUST_LOG="info" \
    DATA_PLANE_ROUTER_HOST="0.0.0.0" \
    DATA_PLANE_ROUTER_PORT="4011" \
    DATA_PLANE_ROUTER_PRODUCT_MODE="shadow"

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app/data-plane-router", "--healthcheck"]

CMD ["/app/data-plane-router"]
