# syntax=docker/dockerfile:1.7
FROM public.ecr.aws/docker/library/node:22-alpine

# python3/make/g++ — native addon builds for some npm deps.
# chromium + font/render libs — headless browser used by the audit toolchain
# (Lighthouse, pa11y). `.npmrc` sets `ignore-scripts=true`, so puppeteer cannot
# download its own browser; we provide a system Chromium and point tools at it.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	apk add --update-cache python3 make g++ \
		chromium nss freetype harfbuzz ca-certificates ttf-freefont

# Enable corepack and install the pinned pnpm version (matches packageManager in package.json).
# docker layer caching keeps this stable across rebuilds.
RUN corepack enable && corepack prepare pnpm@11.5.1 --activate

# Let Lighthouse (chrome-launcher) and puppeteer/pa11y find the system browser
# and skip any download attempt.
ENV CHROME_PATH=/usr/bin/chromium-browser \
	PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
	PUPPETEER_SKIP_DOWNLOAD=true

WORKDIR /workspace/apps/opposite-osiris

COPY apps/opposite-osiris/docker/services/node/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# node:22-alpine ships with a `node` user (UID 1000) — never run npm/pnpm/yarn
# as root. The entrypoint can `sudo`/chown if it really needs to during init.
USER node

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
