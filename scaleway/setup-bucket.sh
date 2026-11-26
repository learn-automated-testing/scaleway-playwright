#!/usr/bin/env bash
# One-time: create the report bucket and a lifecycle rule that deletes old reports.
# Usage: ./scaleway/setup-bucket.sh [bucket-name] [retention-days, default 14]
#        (bucket name defaults to REPORT_BUCKET from .env)
# Safe to re-run (updates the retention period).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

BUCKET="${1:-${REPORT_BUCKET:-}}"
DAYS="${2:-14}"
if [ -z "$BUCKET" ]; then
  echo "Usage: ./scaleway/setup-bucket.sh <bucket-name> [retention-days]"
  echo "  or set REPORT_BUCKET in .env. Bucket names are global across Scaleway, e.g. bsure-pw-reports"
  exit 1
fi
export BUCKET DAYS
export REGION="${SCW_DEFAULT_REGION:-fr-par}"
export ACCESS_KEY="${SCW_ACCESS_KEY:-$(scw config get access-key)}"
export SECRET_KEY="${SCW_SECRET_KEY:-$(scw config get secret-key)}"

node scaleway/setup-bucket.mjs
