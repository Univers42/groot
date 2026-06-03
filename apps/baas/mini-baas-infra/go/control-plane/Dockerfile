# Go control-plane image. Multi-stage build, parameterized by `APP` to keep one
# Dockerfile per cmd binary (adapter-registry, webhook-dispatcher, …).
#
# Build example:
#   docker build --build-arg APP=webhook-dispatcher --build-arg PORT=3025 \
#     -t mini-baas-webhook-dispatcher ./go/control-plane

ARG APP=adapter-registry
ARG PORT=3021

FROM golang:1.23-bookworm AS builder
ARG APP
WORKDIR /src

COPY go.mod go.sum* ./
ENV GOFLAGS=-mod=mod
RUN go mod download all || go mod tidy

COPY . .
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/app ./cmd/${APP}

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
ARG APP
ARG PORT
WORKDIR /app
COPY --from=builder /out/app /app/app

ENV APP=${APP}
EXPOSE ${PORT}
USER nonroot:nonroot
ENTRYPOINT ["/app/app"]
