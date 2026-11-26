#!/usr/bin/env bash
# Set up the Serverless Containers runner and switch the controller to it:
#
#   GitHub webhook -> controller (Function) -> Scaleway Queue -> trigger -> Serverless Container
#
#   1. activate Scaleway Queues, create send/receive credentials (saved to .env)
#   2. create the queue "playwright-runs"
#   3. build/push the image if needed (same image as the job, RUNNER_MODE=server)
#   4. create/update the container (private, scales to zero, 1 run per instance)
#   5. add the queue trigger
#   6. redeploy the controller with RUNNER=container
#
# Switch back to the job any time: set RUNNER=job in .env and run ./scaleway/deploy-controller.sh
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

REGION="${SCW_DEFAULT_REGION:-fr-par}"
NAMESPACE="${SCW_REGISTRY_NAMESPACE:-playwright-tests}"
CT_NAMESPACE="${SCW_CONTAINER_NAMESPACE:-playwright-runner}"
CT_NAME="playwright-runner"
CT_CPU="${SCW_CONTAINER_CPU:-${SCW_JOB_CPU:-4000}}"            # mvCPU
CT_MEMORY_MB="${SCW_CONTAINER_MEMORY:-${SCW_JOB_MEMORY:-8192}}" # MiB
QUEUE_NAME="playwright-runs"
: "${REPORT_BUCKET:?set REPORT_BUCKET in .env}"
: "${REPORT_ACCESS_KEY:?set REPORT_ACCESS_KEY in .env}"
: "${REPORT_SECRET_KEY:?set REPORT_SECRET_KEY in .env}"

json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }
log() { echo "$@" >&2; }
set_env() { # set_env KEY VALUE: write/replace a line in .env (values are never printed)
  KEY="$1" VALUE="$2" python3 - <<'PY'
import os, re
k, v = os.environ['KEY'], os.environ['VALUE']
s = open('.env').read()
s = re.sub(rf'^{k}=.*$', f'{k}={v}', s, flags=re.M) if re.search(rf'^{k}=', s, re.M) else s.rstrip('\n') + f'\n{k}={v}\n'
open('.env', 'w').write(s)
PY
  export "$1=$2"
}

# ---------- 1. Queues + credentials ----------
log "==> Scaleway Queues"
INFO="$(scw mnq sqs get-info region="$REGION" -o json)"
if [ "$(echo "$INFO" | json 'print(d["status"])')" != "enabled" ]; then
  log "    activating (free)"
  scw mnq sqs activate region="$REGION" >/dev/null
  INFO="$(scw mnq sqs get-info region="$REGION" -o json)"
fi
SQS_ENDPOINT="$(echo "$INFO" | json 'print(d["sqs_endpoint_url"])')"

new_creds() { # name publish receive manage -> "access secret"
  scw mnq sqs create-credentials region="$REGION" name="$1" \
    permissions.can-publish="$2" permissions.can-receive="$3" permissions.can-manage="$4" -o json \
    | json 'print(d["access_key"], d["secret_key"])'
}
if [ -z "${SQS_SEND_ACCESS_KEY:-}" ]; then
  log "    creating credentials for the controller (publish + manage)"
  read -r A S <<<"$(new_creds pw-controller-send true false true)"
  set_env SQS_SEND_ACCESS_KEY "$A"; set_env SQS_SEND_SECRET_KEY "$S"
fi
if [ -z "${SQS_RECEIVE_ACCESS_KEY:-}" ]; then
  log "    creating credentials for the trigger (receive only)"
  read -r A S <<<"$(new_creds pw-trigger-receive false true false)"
  set_env SQS_RECEIVE_ACCESS_KEY "$A"; set_env SQS_RECEIVE_SECRET_KEY "$S"
fi
[ -z "${RUN_SECRET:-}" ] && set_env RUN_SECRET "$(openssl rand -hex 32)"

# ---------- 2. Queue ----------
log "==> Queue ${QUEUE_NAME}"
# New credentials can take a few seconds to become valid.
for i in 1 2 3 4 5 6; do
  if QUEUE_URL="$(SQS_ENDPOINT="$SQS_ENDPOINT" REGION="$REGION" QUEUE_NAME="$QUEUE_NAME" \
      ACCESS_KEY="$SQS_SEND_ACCESS_KEY" SECRET_KEY="$SQS_SEND_SECRET_KEY" node scaleway/setup-queue.mjs 2>/tmp/setup-queue.err)"; then
    break
  fi
  [ "$i" = 6 ] && { cat /tmp/setup-queue.err >&2; exit 1; }
  sleep 5
done
set_env SQS_QUEUE_URL "$QUEUE_URL"
log "    ${QUEUE_URL}"

# ---------- 3. Image ----------
. scaleway/image-tag.sh
scw registry login region="$REGION" >/dev/null 2>&1
if ! docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  log "==> Image ${TAG} missing: building via ensure-job.sh (also updates the job)"
  ./scaleway/ensure-job.sh >/dev/null
fi

# ---------- 4. Container ----------
log "==> Container ${CT_NAME} (${CT_CPU} mvCPU, ${CT_MEMORY_MB} MiB)"
NS_ID="$(scw container namespace list region="$REGION" name="$CT_NAMESPACE" -o json | json 'print(d[0]["id"] if d else "")')"
if [ -z "$NS_ID" ]; then
  NS_ID="$(scw container namespace create region="$REGION" name="$CT_NAMESPACE" -o json | json 'print(d["id"])')"
fi
for _ in $(seq 1 60); do
  [ "$(scw container namespace get "$NS_ID" region="$REGION" -o json | json 'print(d["status"])')" = ready ] && break
  sleep 5
done

CT_ARGS=(
  image="$IMAGE"
  mvcpu-limit="$CT_CPU"
  memory-limit-bytes="$((CT_MEMORY_MB / 1024))GB"
  timeout=900s
  privacy=private
  min-scale=0
  max-scale="${SCW_CONTAINER_MAX_SCALE:-3}"
  scaling-option.concurrent-requests-threshold=1
  "environment-variables.RUNNER_MODE=server"
  "environment-variables.REPORT_BUCKET=${REPORT_BUCKET}"
  "environment-variables.REPORT_REGION=${REGION}"
  "secret-environment-variables.REPORT_ACCESS_KEY=${REPORT_ACCESS_KEY}"
  "secret-environment-variables.REPORT_SECRET_KEY=${REPORT_SECRET_KEY}"
  "secret-environment-variables.RUN_SECRET=${RUN_SECRET}"
)
CT_ID="$(scw container container list region="$REGION" namespace-id="$NS_ID" name="$CT_NAME" -o json | json 'print(d[0]["id"] if d else "")')"
if [ -z "$CT_ID" ]; then
  CT_ID="$(scw container container create region="$REGION" namespace-id="$NS_ID" name="$CT_NAME" "${CT_ARGS[@]}" -o json | json 'print(d["id"])')"
else
  scw container container update "$CT_ID" region="$REGION" "${CT_ARGS[@]}" >/dev/null
fi

log "    deploying (a few minutes the first time)"
for i in $(seq 1 120); do
  STATUS="$(scw container container get "$CT_ID" region="$REGION" -o json | json 'print(d["status"], d.get("error_message") or "")')"
  case "$STATUS" in
    ready*) break ;;
    error*) log "    container failed: ${STATUS#error }"; exit 1 ;;
  esac
  [ "$i" = 120 ] && { log "    still deploying after 10 min (status: ${STATUS}); check the console, then re-run"; exit 1; }
  sleep 5
done

# ---------- 5. Trigger ----------
log "==> Queue trigger"
if [ "$(scw container trigger list region="$REGION" container-id="$CT_ID" trigger-type=sqs -o json | json 'print(len(d or []))')" = 0 ]; then
  scw container trigger create region="$REGION" container-id="$CT_ID" name=playwright-runs \
    destination-config.http-path=/run destination-config.http-method=post \
    sqs-config.region="$REGION" sqs-config.endpoint="$SQS_ENDPOINT" sqs-config.queue-url="$QUEUE_URL" \
    sqs-config.access-key-id="$SQS_RECEIVE_ACCESS_KEY" sqs-config.secret-access-key="$SQS_RECEIVE_SECRET_KEY" >/dev/null
fi

# ---------- 6. Controller ----------
log "==> Switching controller to RUNNER=container"
set_env RUNNER container
./scaleway/deploy-controller.sh

log ""
log "Done. Next push runs on Serverless Containers. Back to jobs: RUNNER=job in .env + ./scaleway/deploy-controller.sh"
