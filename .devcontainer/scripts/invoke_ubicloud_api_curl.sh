#!/bin/bash
# Wrapper for the local Ubicloud API. Handles token acquisition automatically.
# Use "default" as the project ID and it will be resolved automatically.
#
# Usage:
#   invoke_ubicloud_api_curl.sh <method> <path> [extra curl args...]
#   invoke_ubicloud_api_curl.sh GET /project
#   invoke_ubicloud_api_curl.sh GET /project/default/location/aws-us-west-2/postgres
#   invoke_ubicloud_api_curl.sh POST /project/default/location/aws-us-west-2/postgres/mydb -d '{"size":"m8gd.large","storage_size":118}'
#   invoke_ubicloud_api_curl.sh DELETE /project/default/location/aws-us-west-2/postgres/mydb

set -e

METHOD="${1:?Usage: invoke_ubicloud_api_curl.sh <METHOD> <path> [curl args...]}"
PATH_ARG="${2:?Usage: invoke_ubicloud_api_curl.sh <METHOD> <path> [curl args...]}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TOKEN=$(cd "$PROJECT_ROOT" && .devcontainer/scripts/get-pat-token.sh)
API="http://api.localhost:3100"

# Resolve "default" project ID placeholder
if [[ "$PATH_ARG" == */project/default/* || "$PATH_ARG" == /project/default ]]; then
  DEFAULT_PROJECT_ID=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/project" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  PATH_ARG="${PATH_ARG/\/project\/default/\/project\/$DEFAULT_PROJECT_ID}"
fi

exec curl -s -X "$METHOD" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API$PATH_ARG" \
  "$@"
