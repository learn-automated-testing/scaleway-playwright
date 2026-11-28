# Runtime image: Node + Chromium (headless shell only) + npm dependencies.
# ~1 GB instead of ~2 GB for the official Playwright image (which also ships Firefox and WebKit),
# so cold starts on Scaleway pull less.
# Tests are NOT baked in - they are downloaded for the exact commit at startup,
# so this image only needs rebuilding when dependencies or scripts change.
FROM node:22-bookworm-slim

WORKDIR /app
ENV CI=true \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci \
 && npx playwright install --with-deps --only-shell chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

COPY scripts ./scripts
# SQS client shared with the controller (used by the KEDA worker)
COPY controller/sqs.js controller/package.json ./controller/

# Jobs: run once and exit. Containers: set RUNNER_MODE=server.
ENTRYPOINT ["./scripts/entrypoint.sh"]
