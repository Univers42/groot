# syntax=docker/dockerfile:1.7
FROM public.ecr.aws/docker/library/node:22-alpine

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	apk add --update-cache python3 make g++

WORKDIR /workspace/apps/opposite-osiris

COPY apps/opposite-osiris/docker/services/node/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# node:22-alpine ships with a `node` user (UID 1000) — never run npm/pnpm/yarn
# as root. The entrypoint can `sudo`/chown if it really needs to during init.
USER node

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
