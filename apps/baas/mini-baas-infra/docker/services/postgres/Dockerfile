# syntax=docker/dockerfile:1.7
# File: docker/services/postgres/Dockerfile
# PostgreSQL 16 with pg_net extension (required by GoTrue webhooks / Supabase).

FROM postgres:16

# Install build dependencies for pg_net
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
  && apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    libcurl4-openssl-dev \
    postgresql-server-dev-16 \
  && git clone --depth 1 --branch v0.14.0 https://github.com/supabase/pg_net.git /tmp/pg_net \
  && cd /tmp/pg_net \
  && sed -i \
    -e 's/CURLOPT_POST, 1)/CURLOPT_POST, 1L)/' \
    -e 's/CURLOPT_POSTFIELDSIZE, 0)/CURLOPT_POSTFIELDSIZE, 0L)/' \
    -e 's/CURLOPT_TIMEOUT_MS, cdata->timeout_milliseconds)/CURLOPT_TIMEOUT_MS, (long)cdata->timeout_milliseconds)/' \
    -e 's/CURLOPT_FOLLOWLOCATION, true)/CURLOPT_FOLLOWLOCATION, 1L)/' \
    src/core.c \
  && make \
  && make install \
  && rm -rf /tmp/pg_net \
  && apt-get purge -y --auto-remove \
    build-essential \
    git \
    postgresql-server-dev-16

EXPOSE 5432
