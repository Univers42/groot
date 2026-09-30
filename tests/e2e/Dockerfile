# The runner: the official image at the exact @playwright/test version the lockfile pins,
# plus certutil so the grobase local CA can be trusted instead of ignoring HTTPS errors.
FROM mcr.microsoft.com/playwright:v1.63.0-noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends libnss3-tools \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /e2e
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["npx", "playwright", "test"]
