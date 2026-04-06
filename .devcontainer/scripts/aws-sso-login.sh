#!/bin/bash
# Authenticates with AWS SSO using the configured profile.
#
# Usage: .devcontainer/scripts/aws-sso-login.sh

set -euo pipefail

AWS_PROFILE="${AWS_LOGIN_PROFILE:-pg-dev-postgresqladmindev}"

echo "=== AWS SSO login ==="
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo "AWS credentials available in environment — skipping SSO login"
elif aws sts get-caller-identity --profile="$AWS_PROFILE" >/dev/null 2>&1; then
  echo "AWS SSO session already active"
else
  echo "Logging in to AWS SSO..."
  aws sso login --profile="$AWS_PROFILE"
fi
