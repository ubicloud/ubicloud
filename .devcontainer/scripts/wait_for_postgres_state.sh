#!/bin/bash
# Polls a PostgreSQL server until it reaches the desired state.
#
# Usage:
#   wait_for_postgres_state.sh <name> <state> [timeout_seconds]
#   wait_for_postgres_state.sh e2e-test running
#   wait_for_postgres_state.sh e2e-test running 600
#
# Exits 0 when the state is reached, 1 on timeout.
# Uses "default" project and aws-us-west-2 location.

set -e

NAME="${1:?Usage: wait_for_postgres_state.sh <name> <state> [timeout_seconds]}"
TARGET_STATE="${2:?Usage: wait_for_postgres_state.sh <name> <state> [timeout_seconds]}"
TIMEOUT="${3:-600}"
INTERVAL=15

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  # For "deleted" state, check for 404
  if [ "$TARGET_STATE" = "deleted" ]; then
    HTTP_CODE=$("$SCRIPT_DIR/invoke_ubicloud_api_curl.sh" GET \
      "/project/default/location/aws-us-west-2/postgres/$NAME" \
      -o /dev/null -w "%{http_code}")
    STATE="$HTTP_CODE"
    [ "$HTTP_CODE" = "404" ] && TARGET_STATE_LABEL="deleted (404)" && STATE="deleted"
  else
    STATE=$("$SCRIPT_DIR/invoke_ubicloud_api_curl.sh" GET \
      "/project/default/location/aws-us-west-2/postgres/$NAME" | jq -r '.state')
  fi

  echo "$(date +%H:%M:%S) $NAME state=$STATE"

  if [ "$STATE" = "$TARGET_STATE" ]; then
    echo "Reached state: $TARGET_STATE"
    exit 0
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "Timeout waiting for $NAME to reach state: $TARGET_STATE" >&2
exit 1
