# syntax=docker/dockerfile:1.7
FROM node:22-alpine

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	apk add --update-cache bash git python3 make g++

WORKDIR /workspace/apps/opposite-osiris

COPY apps/opposite-osiris/docker/services/node/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
