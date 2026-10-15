# groot-tools: the one-shot toolbox for the website redesign, its media pipeline and the browser
# MCP servers, so nothing is installed on the host (docs/redesign/DECISIONS.md D-004). It is not
# a daemon. Every use is `scripts/tools.sh <command> …`, a --rm container, which builds this
# image on demand under a tag derived from the files that define it.
#
# Pins are exact and were at least two weeks old when chosen (2026-10-15). Bump them here only.
ARG ALPINE_IMAGE=public.ecr.aws/docker/library/alpine:3.24.2
ARG GO_IMAGE=public.ecr.aws/docker/library/golang:1.26.9

FROM ${GO_IMAGE} AS grobase-cli
# Univers42/grobase-cli main, 2026-10-12. Packaged as-is (D-005); flags as in its own build.
ARG GROBASE_CLI_REF=112a848da0fd6b016318d7293e2819d6ad1c5bf5
RUN git clone --filter=blob:none https://github.com/Univers42/grobase-cli.git /src \
 && git -C /src checkout --detach "$GROBASE_CLI_REF"
WORKDIR /src
RUN short="$(printf %.7s "$GROBASE_CLI_REF")" \
 && CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.version=${short} -X main.commit=${GROBASE_CLI_REF} -X main.date=pinned" \
      -o /out/grobase ./cmd/grobase

FROM ${ALPINE_IMAGE}
# chromium + nss-tools: Lighthouse, both browser MCPs, and the CA import the entrypoint does.
# ffmpeg, vips (+heif for AVIF), imagemagick: video and image conversion. Fonts so a headless
# capture renders text instead of tofu.
RUN apk add --no-cache bash ca-certificates nss-tools chromium ffmpeg vips-tools vips-heif \
      imagemagick nodejs npm font-noto font-noto-emoji ttf-dejavu
ARG SVGO_VERSION=4.1.0
ARG LHCI_VERSION=0.15.1
ARG CHROME_DEVTOOLS_MCP_VERSION=1.10.1
ARG PLAYWRIGHT_MCP_VERSION=0.0.83
RUN npm install -g --no-audit --no-fund --no-update-notifier \
      "svgo@${SVGO_VERSION}" "@lhci/cli@${LHCI_VERSION}" \
      "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
 && npm cache clean --force
COPY --from=grobase-cli /out/grobase /usr/local/bin/grobase
COPY --from=e2e docker-entrypoint.sh /usr/local/bin/ca-trust-entrypoint
# The browser every tool drives is this image's Chromium; nothing downloads another one.
ENV CHROME_PATH=/usr/bin/chromium-browser \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    CA_REQUIRED=0 \
    NPM_CONFIG_UPDATE_NOTIFIER=false
ENTRYPOINT ["ca-trust-entrypoint"]
CMD ["sh"]
