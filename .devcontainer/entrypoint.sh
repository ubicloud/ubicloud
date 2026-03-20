#!/bin/bash
set -e

MARKER_FILE="/tmp/.container_initialized"

# Copy host .gitconfig if it was mounted as a file (Docker creates a directory if the host file doesn't exist)
if [ -f /tmp/.host-gitconfig ]; then
  cp /tmp/.host-gitconfig /home/vscode/.gitconfig
  chown vscode:vscode /home/vscode/.gitconfig
fi


# Run once on first start (equivalent to postCreateCommand)
if [ ! -f "$MARKER_FILE" ]; then
  echo "=== First start: initializing sql users and databases ==="
  psql -U postgres -d postgres -f ch-internal/scripts/create-users.sql || true
  psql -U postgres -d postgres -f ch-internal/scripts/create-db.sql || true
  bundle exec rake 'setup_database[development,false]'
  bundle exec rake 'setup_database[test,true]'
  touch "$MARKER_FILE"
fi

# Regenerate .env.rb and append overrides
echo "=== Generating .env.rb ==="
rake overwrite_envrb
if [ -f ".devcontainer/env-overrides.rb" ]; then
  cat .devcontainer/env-overrides.rb >> .env.rb
  echo "Appended env-overrides.rb to .env.rb"
fi

# Run on every start (equivalent to postStartCommand)
echo "=== Setting up databases ==="
bundle exec rake dev_up
npm ci
npm run prod

# Start foreman in background (idempotent — skips if already running)
echo "=== Starting foreman in background ==="
.devcontainer/scripts/start-foreman.sh || true

echo ""
echo "========================================"
echo "  Container is ready!"
echo "========================================"
echo ""
echo "  Connect in a new terminal (if not running in devcontainer):"
echo "    docker compose -f .devcontainer/docker-compose.yml exec app bash"
echo ""
echo "  Run the setup script (first time only):"
echo "    .devcontainer/scripts/prepare-pg-ubicloud.sh"
echo ""
echo "  Refresh AWS credentials:"
echo "    aws sso login --profile=pg-dev-postgresqladmindev"
echo ""
echo "  Foreman starts automatically. To follow logs:"
echo "    tail -f /var/log/foreman/foreman.log"
echo ""
echo "========================================"

# Execute the passed command (sleep infinity, bash, etc.)
exec "$@"
