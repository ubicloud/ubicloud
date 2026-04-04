#!/bin/bash
# Starts foreman in the background, streaming logs to /var/log/foreman/foreman.log.
# Detects running foreman by process name instead of PID file.
#
# Usage: start-foreman.sh [--restart]
#   --restart  Stop any running foreman instance first, then start fresh.
#              Without this flag, exits early if foreman is already running.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="/var/log/foreman"
LOG_FILE="$LOG_DIR/foreman.log"

RESTART=false
for arg in "$@"; do
  [[ "$arg" == "--restart" ]] && RESTART=true
done

is_foreman_running() {
  pgrep -f "foreman: main" > /dev/null 2>&1
}

stop_foreman() {
  if is_foreman_running; then
    echo "=== Stopping foreman ==="
    pkill -f "foreman: main" 2>/dev/null
    # Wait for it to exit
    for i in $(seq 1 10); do
      is_foreman_running || break
      sleep 1
    done
    # Force kill if still running
    if is_foreman_running; then
      pkill -9 -f "foreman: main" 2>/dev/null || true
    fi
    echo "Foreman stopped"
  fi
}

# If already running, either exit early or stop first
if is_foreman_running; then
  if [ "$RESTART" = true ]; then
    stop_foreman
  else
    echo "Foreman already running"
    echo "  tail -f $LOG_FILE"
    exit 0
  fi
fi

# Start foreman
sudo mkdir -p "$LOG_DIR"
sudo chown vscode:vscode "$LOG_DIR"
cd "$WORKDIR"
echo "=== Starting foreman (log: $LOG_FILE) ==="
RACK_ENV=development PORT="${PORT:-3100}" bundle exec foreman start >> "$LOG_FILE" 2>&1 &
echo "Foreman started (PID: $!)"
echo "  tail -f $LOG_FILE"

# Set up logrotate config (idempotent)
sudo tee /etc/logrotate.d/foreman > /dev/null <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# Start cron for log rotation if not already running
if ! pgrep -x cron > /dev/null 2>&1; then
  echo "=== Starting cron for log rotation ==="
  sudo cron
fi
