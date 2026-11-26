#!/usr/bin/env bash
# Deploy the webhook controller (controller/handler.js) as a Scaleway Serverless Function,
# with a cron trigger that runs the sweeper every 15 minutes.
# Prints the webhook URL to paste into the GitHub App settings.
#
# Needs in .env (see .env.example):
#   GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY_FILE, GITHUB_WEBHOOK_SECRET
#   JOB_DEFINITION_ID (from ./scaleway/ensure-job.sh)
#   optional: CONTROLLER_SCW_SECRET_KEY (API key that may start jobs; defaults to your scw CLI key),
#             REPORT_BUCKET, REPORT_ACCESS_KEY, REPORT_SECRET_KEY, BASE_URL, BRANCHES
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

REGION="${SCW_DEFAULT_REGION:-fr-par}"
NS_NAME="${SCW_FUNCTION_NAMESPACE:-playwright-ci}"
FN_NAME="github-webhook"
: "${GITHUB_APP_ID:?set GITHUB_APP_ID}"
: "${GITHUB_APP_PRIVATE_KEY_FILE:?set GITHUB_APP_PRIVATE_KEY_FILE (path to the .pem from GitHub)}"
: "${GITHUB_WEBHOOK_SECRET:?set GITHUB_WEBHOOK_SECRET (e.g. openssl rand -hex 32)}"
: "${JOB_DEFINITION_ID:?set JOB_DEFINITION_ID (output of ./scaleway/ensure-job.sh)}"
CONTROLLER_SCW_SECRET_KEY="${CONTROLLER_SCW_SECRET_KEY:-$(scw config get secret-key)}"

json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# scw has no "wait" for functions: poll until status is ready (or fail on error).
wait_ready() { # <namespace|function> <id>
  local status
  for _ in $(seq 1 60); do
    status="$(scw function "$1" get "$2" region="$REGION" -o json | json 'print(d["status"], d.get("error_message") or "")')"
    case "$status" in
      ready*) return 0 ;;
      error*) echo "    $1 $2 failed: ${status#error }" >&2; return 1 ;;
    esac
    sleep 5
  done
  echo "    timed out waiting for $1 $2 (last status: $status)" >&2; return 1
}

echo "==> Function namespace ${NS_NAME}"
NS_ID="$(scw function namespace list region="$REGION" name="$NS_NAME" -o json | json 'print(d[0]["id"] if d else "")')"
if [ -z "$NS_ID" ]; then
  NS_ID="$(scw function namespace create region="$REGION" name="$NS_NAME" -o json | json 'print(d["id"])')"
  echo "    created ${NS_ID}, waiting until ready"
  wait_ready namespace "$NS_ID"
fi

echo "==> Uploading code"
ZIP="$(mktemp -d)/controller.zip"
(cd controller && zip -q "$ZIP" handler.js)
scw function deploy region="$REGION" namespace-id="$NS_ID" name="$FN_NAME" runtime=node22 zip-file="$ZIP" >/dev/null
FN_ID="$(scw function function list region="$REGION" namespace-id="$NS_ID" name="$FN_NAME" -o json | json 'print(d[0]["id"])')"

echo "==> Configuring (handler, env, secrets)"
SECRETS=(
  GITHUB_APP_PRIVATE_KEY_B64 "$(base64 < "$GITHUB_APP_PRIVATE_KEY_FILE" | tr -d '\n')"
  GITHUB_WEBHOOK_SECRET "$GITHUB_WEBHOOK_SECRET"
  JOBS_SECRET_KEY "$CONTROLLER_SCW_SECRET_KEY"
)
[ -n "${REPORT_BUCKET:-}" ] && SECRETS+=(
  REPORT_ACCESS_KEY "${REPORT_ACCESS_KEY:?REPORT_ACCESS_KEY required with REPORT_BUCKET}"
  REPORT_SECRET_KEY "${REPORT_SECRET_KEY:?REPORT_SECRET_KEY required with REPORT_BUCKET}"
)
SECRET_ARGS=()
for ((i = 0; i < ${#SECRETS[@]}; i += 2)); do
  n=$((i / 2))
  SECRET_ARGS+=("secret-environment-variables.${n}.key=${SECRETS[i]}" "secret-environment-variables.${n}.value=${SECRETS[i+1]}")
done

scw function function update "$FN_ID" region="$REGION" \
  handler=handler.handle privacy=public min-scale=0 memory-limit=256 timeout=30s \
  "environment-variables.GITHUB_APP_ID=${GITHUB_APP_ID}" \
  "environment-variables.JOB_DEFINITION_ID=${JOB_DEFINITION_ID}" \
  "environment-variables.JOBS_REGION=${REGION}" \
  "environment-variables.BASE_URL=${BASE_URL:-https://www.practiceautomatedtesting.com}" \
  "environment-variables.BRANCHES=${BRANCHES:-}" \
  "environment-variables.ALLOWED_REPOS=${ALLOWED_REPOS:?set ALLOWED_REPOS, e.g. learn-automated-testing/scaleway-playwright}" \
  "environment-variables.REPORT_BUCKET=${REPORT_BUCKET:-}" \
  "${SECRET_ARGS[@]}" >/dev/null

echo "==> Deploying (1-2 min)"
scw function function deploy "$FN_ID" region="$REGION" >/dev/null
sleep 5
wait_ready function "$FN_ID"

echo "==> Sweeper cron (every 15 min)"
if [ "$(scw function cron list region="$REGION" function-id="$FN_ID" -o json | json 'print(len(d or []))')" = 0 ]; then
  scw function cron create region="$REGION" function-id="$FN_ID" name=sweep \
    schedule='*/15 * * * *' args='{"action":"sweep"}' >/dev/null
fi

DOMAIN="$(scw function function get "$FN_ID" region="$REGION" -o json | json 'print(d["domain_name"])')"
echo
echo "Webhook URL for your GitHub App:  https://${DOMAIN}"
