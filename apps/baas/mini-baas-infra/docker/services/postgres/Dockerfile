# syntax=docker/dockerfile:1.7
# File: docker/services/postgres/Dockerfile
# PostgreSQL 16 Alpine with pg_net extension (required by GoTrue webhooks / Supabase).

FROM public.ecr.aws/docker/library/postgres:16-alpine AS pg_net_builder

ARG PG_NET_VERSION=0.14.0
ADD https://github.com/supabase/pg_net/archive/refs/tags/v${PG_NET_VERSION}.tar.gz /tmp/pg_net.tar.gz

# Install build dependencies for pg_net
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --no-cache --virtual .pg-net-build-deps \
    build-base \
    ca-certificates \
    curl-dev \
  && tar -xzf /tmp/pg_net.tar.gz -C /tmp \
  && mv "/tmp/pg_net-${PG_NET_VERSION}" /tmp/pg_net \
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
  && apk del .pg-net-build-deps \
  && rm -rf /tmp/pg_net /tmp/pg_net.tar.gz /var/cache/apk/*

FROM public.ecr.aws/docker/library/postgres:16-alpine

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
  apk add --no-cache ca-certificates libcurl

COPY --from=pg_net_builder /usr/local/lib/postgresql/pg_net.so /usr/local/lib/postgresql/
COPY --from=pg_net_builder /usr/local/share/postgresql/extension/pg_net* /usr/local/share/postgresql/extension/

EXPOSE 5432
