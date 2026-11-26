#!/usr/bin/env bash
# Delete old runtime image tags from Container Registry.
# Keeps the newest KEEP tags (default 3) and always the tag the job definition uses.
# Usage: ./scaleway/cleanup-images.sh [--dry-run]
set -euo pipefail

REGION="${SCW_DEFAULT_REGION:-fr-par}"
NAMESPACE="${SCW_REGISTRY_NAMESPACE:-playwright-tests}"
JOB_NAME="${SCW_JOB_NAME:-practiceautomatedtesting-e2e}"
KEEP="${KEEP:-3}"
DRY_RUN="${1:-}"

json() { python3 -c "import json,sys; d=json.load(sys.stdin) or []; $1"; }

NS_ID="$(scw registry namespace list region="$REGION" name="$NAMESPACE" -o json | json 'print(d[0]["id"] if d else "")')"
[ -z "$NS_ID" ] && { echo "Namespace ${NAMESPACE} not found"; exit 0; }
IMAGE_ID="$(scw registry image list region="$REGION" namespace-id="$NS_ID" name=playwright-e2e -o json | json 'print(d[0]["id"] if d else "")')"
[ -z "$IMAGE_ID" ] && { echo "No playwright-e2e image yet"; exit 0; }

IN_USE="$(scw jobs definition list region="$REGION" -o json \
  | JOB_NAME="$JOB_NAME" json 'import os; d=[j for j in d if j["name"]==os.environ["JOB_NAME"]]; print(d[0]["image_uri"].rsplit(":",1)[1] if d else "")')"

scw registry tag list image-id="$IMAGE_ID" region="$REGION" order-by=created_at_desc -o json \
  | json 'print("\n".join(t["id"] + " " + t["name"] for t in d))' \
  | tail -n +"$((KEEP + 1))" \
  | while read -r TAG_ID TAG_NAME; do
      if [ "$TAG_NAME" = "$IN_USE" ]; then echo "keep   ${TAG_NAME} (used by job)"; continue; fi
      if [ "$DRY_RUN" = "--dry-run" ]; then echo "would delete ${TAG_NAME}"; continue; fi
      echo "delete ${TAG_NAME}"
      scw registry tag delete "$TAG_ID" region="$REGION" >/dev/null
    done
