FROM node:22-alpine

RUN apk add --no-cache bash git python3 make g++

WORKDIR /workspace/apps/opposite-osiris

COPY apps/opposite-osiris/docker/services/node/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
