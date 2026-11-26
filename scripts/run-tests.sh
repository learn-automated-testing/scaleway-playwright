#!/usr/bin/env bash
# Container entrypoint (Scaleway Serverless Job).
#   1. mark the GitHub check run "in progress"
#   2. download tests + playwright.config.ts for GIT_SHA from GitHub
#   3. run Playwright
#   4. upload the HTML report to Object Storage (optional)
#   5. complete the check run (pass/fail, failed tests, annotations, report link)
#   6. exit with the test result -> job run state succeeded / failed
# Any unexpected exit before step 5 marks the check run as failed (trap).
set -uo pipefail
cd /app

# A container instance can handle several runs in a row: start from a clean slate.
rm -rf /tmp/src /tmp/report-url playwright-report test-results

REPORTED=0
on_exit() {
  if [ "$REPORTED" = 0 ]; then
    node scripts/github-check.mjs crash "Job exited before reporting results (step: ${STEP:-unknown}). See the job run logs in the Scaleway console." || true
  fi
}
trap on_exit EXIT

STEP="start"
node scripts/github-check.mjs start || echo "[run-tests] could not update check run"

STEP="fetch sources"
if [ -n "${GIT_SHA:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  echo "[run-tests] Fetching tests for ${GITHUB_REPOSITORY}@${GIT_SHA}"
  auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  mkdir -p /tmp/src
  if ! curl -fsSL ${auth[@]+"${auth[@]}"} \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/tarball/${GIT_SHA}" \
      | tar -xz -C /tmp/src --strip-components=1; then
    echo "[run-tests] fetching sources failed"; exit 2
  fi
  rm -rf tests && cp -r /tmp/src/tests ./tests && cp /tmp/src/playwright.config.ts ./
elif [ ! -d tests ]; then
  echo "[run-tests] No tests: set GIT_SHA + GITHUB_REPOSITORY, or mount ./tests and playwright.config.ts into /app"
  exit 2
fi

STEP="playwright"
npx playwright test "$@"
status=$?

STEP="upload report"
node scripts/upload-report.mjs || echo "[run-tests] report upload failed"

STEP="report check run"
node scripts/github-check.mjs complete && REPORTED=1 || echo "[run-tests] could not complete check run"

exit $status
