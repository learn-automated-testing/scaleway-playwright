#!/usr/bin/env bash
# Make sure the runtime image and the Serverless Job definition exist.
# The image tag is a hash of the files baked into the image, so a build + push
# only happens when Dockerfile, package*.json or scripts/ change.
#
# Prints the job definition id on stdout (everything else goes to stderr).
# Env: SCW_DEFAULT_REGION (fr-par), SCW_REGISTRY_NAMESPACE, SCW_JOB_NAME,
#      SCW_JOB_CPU (mvCPU), SCW_JOB_MEMORY (MiB) + scw CLI credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="${SCW_DEFAULT_REGION:-fr-par}"
NAMESPACE="${SCW_REGISTRY_NAMESPACE:-playwright-tests}"
JOB_NAME="${SCW_JOB_NAME:-practiceautomatedtesting-e2e}"
CPU="${SCW_JOB_CPU:-4000}"        # 4 vCPU: one Playwright worker per vCPU (no GPU, Chromium renders on CPU)
MEMORY="${SCW_JOB_MEMORY:-8192}"  # 8 GiB: 2 GiB per browser worker
STORAGE="${SCW_JOB_STORAGE:-5000}" # MiB local disk: Playwright image + report

. scaleway/image-tag.sh   # sets IMAGE (tag = hash of Dockerfile, package*.json, scripts/)
log() { echo "$@" >&2; }

if ! scw registry namespace list region="$REGION" name="$NAMESPACE" -o json | grep -q "\"name\":\"${NAMESPACE}\""; then
  log "==> Creating registry namespace ${NAMESPACE}"
  scw registry namespace create name="$NAMESPACE" region="$REGION" is-public=false >/dev/null
fi

scw registry login region="$REGION" >/dev/null 2>&1
if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  log "==> Image ${IMAGE} already exists, skipping build"
else
  log "==> Building and pushing ${IMAGE}"
  docker build --platform linux/amd64 -t "$IMAGE" . >&2
  docker push "$IMAGE" >&2
  BUILT=1
fi

JOB_ID="$(scw jobs definition list region="$REGION" -o json \
  | JOB_NAME="$JOB_NAME" python3 -c 'import json,os,sys; d=[j for j in json.load(sys.stdin) or [] if j["name"]==os.environ["JOB_NAME"]]; print(d[0]["id"] if d else "")')"

if [ -z "$JOB_ID" ]; then
  log "==> Creating job definition ${JOB_NAME}"
  JOB_ID="$(scw jobs definition create region="$REGION" name="$JOB_NAME" \
    image-uri="$IMAGE" cpu-limit="$CPU" memory-limit="$MEMORY" local-storage-capacity="$STORAGE" job-timeout=1200s \
    description="Playwright E2E tests (triggered by GitHub App webhook)" -o json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  CURRENT="$(scw jobs definition get "$JOB_ID" region="$REGION" -o json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["image_uri"], d["cpu_limit"], d["memory_limit"])')"
  WANTED="${IMAGE} ${CPU} ${MEMORY}"
  if [ "$CURRENT" != "$WANTED" ]; then
    log "==> Updating job definition: image ${IMAGE}, ${CPU} mvCPU, ${MEMORY} MiB"
    scw jobs definition update "$JOB_ID" region="$REGION" \
      image-uri="$IMAGE" cpu-limit="$CPU" memory-limit="$MEMORY" >/dev/null
  fi
fi

# A new image was pushed: drop old tags (keeps newest 3 + the one in use).
[ "${BUILT:-0}" = 1 ] && ./scaleway/cleanup-images.sh >&2 || true

echo "$JOB_ID"
