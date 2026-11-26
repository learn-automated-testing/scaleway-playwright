# Runtime image: Playwright browsers + npm dependencies only.
# Tests are NOT baked in - the job downloads them for the exact commit at startup,
# so this image only needs rebuilding when dependencies or scripts change.
# Keep the tag in sync with @playwright/test in package.json.
FROM mcr.microsoft.com/playwright:v1.65.1-noble

WORKDIR /app
ENV CI=true

COPY package.json package-lock.json ./
RUN npm ci

COPY scripts ./scripts

ENTRYPOINT ["./scripts/run-tests.sh"]
