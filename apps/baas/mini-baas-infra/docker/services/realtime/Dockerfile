# syntax=docker/dockerfile:1
# File: docker/services/realtime/Dockerfile

FROM dlesieur/realtime-agnostic@sha256:a96024e9c3d27cd452310ea6f4c7cfa965c6ee685a26ece58325361c924d5ecd
EXPOSE 4000
USER 1001:1001

# realtime-agnostic exposes /v1/health on port 4000 (Rust HTTP server).
# Try curl first, fall back to wget if only one tool is present in the base image.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD sh -c 'curl -fsS http://localhost:4000/v1/health >/dev/null 2>&1 || wget -qO- http://localhost:4000/v1/health >/dev/null 2>&1' || exit 1
