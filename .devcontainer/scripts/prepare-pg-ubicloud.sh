#!/bin/bash
# Prepares the Ubicloud environment for PostgreSQL development.
# Authenticates with GitHub, fetches latest AMIs, and updates the database.
#
# Usage: .devcontainer/prepare-pg-ubicloud.sh [--region us-west-2] [--region us-east-1]
#   --region: AWS region(s) to update (default: us-west-2). Can be specified multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGIONS=()

: "${AWS_ASSUME_ROLE:?AWS_ASSUME_ROLE is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGIONS+=("$2")
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--region us-west-2] [--region us-east-1]" >&2
      exit 1
      ;;
  esac
done

# Default to us-west-2 if no regions specified
if [ ${#REGIONS[@]} -eq 0 ]; then
  REGIONS=("us-west-2")
fi

# 1. Create default project with private_locations enabled
"$SCRIPT_DIR/register-pg-project.sh"

# Start foreman (always restart to pick up any config changes)
"$SCRIPT_DIR/start-foreman.sh" --restart

# 2. GitHub authentication
echo ""
echo "=== GitHub CLI authentication ==="
if [ -n "${GH_TOKEN:-}" ]; then
  echo "Using GH_TOKEN — skipping interactive login"
else
  gh auth status 2>/dev/null || gh auth login
fi

# 3. Download AWS config (skip when credentials are already in environment)
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo ""
  echo "=== AWS credentials available in environment — skipping ~/.aws/config download ==="
else
  echo ""
  echo "=== Downloading AWS config ==="
  mkdir -p ~/.aws
  sudo chown -R "$(id -u):$(id -g)" ~/.aws
  gh api /repos/ClickHouse/data-plane-configuration/contents/aws-config \
    -H "Accept: application/vnd.github.raw" > ~/.aws/config
  echo "AWS config written to ~/.aws/config"
fi

# 4. Register regions (create locations + fetch and update AMIs)
for REGION in "${REGIONS[@]}"; do
  "$SCRIPT_DIR/register-pg-region.sh" "$REGION" "$AWS_ASSUME_ROLE"
done

"$SCRIPT_DIR/aws-sso-login.sh"

echo ""
echo "=== Done ==="
