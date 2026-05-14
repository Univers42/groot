# syntax=docker/dockerfile:1.7
# File: docker/services/postgres/Dockerfile
# PostgreSQL 16 Alpine with pg_net extension (required by GoTrue webhooks / Supabase).

FROM postgres:16-alpine

# Install build dependencies for pg_net
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --update-cache \
    build-base \
    ca-certificates \
    curl-dev \
    git \
  && git clone --depth 1 --branch v0.14.0 https://github.com/supabase/pg_net.git /tmp/pg_net \
  && cd /tmp/pg_net \
  && sed -i \
    -e 's/CURLOPT_POST, 1)/CURLOPT_POST, 1L)/' \
    -e 's/CURLOPT_POSTFIELDSIZE, 0)/CURLOPT_POSTFIELDSIZE, 0L)/' \
    -e 's/CURLOPT_TIMEOUT_MS, cdata->timeout_milliseconds)/CURLOPT_TIMEOUT_MS, (long)cdata->timeout_milliseconds)/' \
    -e 's/CURLOPT_FOLLOWLOCATION, true)/CURLOPT_FOLLOWLOCATION, 1L)/' \
    src/core.c \
  && sed -i '1i#define CURL_DISABLE_TYPECHECK 1' src/core.c src/event.h src/errors.c src/util.c src/worker.c \
  && make with_llvm=no \
  && make install with_llvm=no \
  && rm -rf /tmp/pg_net /var/cache/apk/*

EXPOSE 5432
