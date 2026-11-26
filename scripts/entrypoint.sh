#!/usr/bin/env bash
# One image, two modes:
#   RUNNER_MODE=server -> HTTP server for Scaleway Serverless Containers (queue trigger)
#   otherwise          -> run the tests once and exit (Scaleway Serverless Jobs)
if [ "${RUNNER_MODE:-}" = "server" ]; then
  exec node scripts/server.mjs
fi
exec ./scripts/run-tests.sh "$@"
