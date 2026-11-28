#!/usr/bin/env bash
# One image, two modes:
#   RUNNER_MODE=server -> HTTP server for Scaleway Serverless Containers (queue trigger)
#   RUNNER_MODE=worker -> take one message from the queue and run it (Kubernetes Job started by KEDA)
#   otherwise          -> run the tests once and exit (Scaleway Serverless Jobs)
if [ "${RUNNER_MODE:-}" = "server" ]; then
  exec node scripts/server.mjs
fi
if [ "${RUNNER_MODE:-}" = "worker" ]; then
  exec node scripts/sqs-worker.mjs
fi
exec ./scripts/run-tests.sh "$@"
