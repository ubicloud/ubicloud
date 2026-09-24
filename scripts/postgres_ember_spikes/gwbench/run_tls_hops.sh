#!/bin/bash
# How much of the gateway's CPU is the second TLS session?
#
# Compares the design as written (client TLS terminated, second TLS session to
# the ember) against the option where the ember runs PostgreSQL without ssl
# and the hop is encrypted below PostgreSQL.
set -uo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
if [[ ! -f cert.pem ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout key.pem \
    -out cert.pem -days 365 -nodes -subj "/CN=gwbench" >/dev/null 2>&1
fi
$GO build -o upstream upstream.go && $GO build -o gateway-go gateway.go && $GO build -o client client.go

pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
cpu_of() { awk '{print ($14+$15)}' /proc/$1/stat 2>/dev/null; }

run_case() {
  local label=$1 upstream_mode=$2 gw_mode=$3 upstream=127.0.0.1:7011 gw=127.0.0.1:7444
  ./upstream $upstream $upstream_mode & local up=$!; pids+=($up); sleep 1
  ./gateway-go $gw $upstream $gw_mode & local gwpid=$!; pids+=($gwpid); sleep 1
  echo "### $label ###"
  for spec in "throughput 1048576 50" "latency 64 100"; do
    set -- $spec
    local c0=$(cpu_of $gwpid)
    local out=$(./client -addr $gw -mode $1 -size $2 -conns $3 -duration 10s)
    local c1=$(cpu_of $gwpid)
    echo "  $1 conns=$3  $out  gateway_cpu=$(echo "scale=0; ($c1-$c0)/10" | bc)%"
  done
  kill $gwpid $up 2>/dev/null; wait $gwpid $up 2>/dev/null; sleep 1
}

run_case "double TLS (design as written)" "" ""
run_case "client TLS only (hop encrypted below PostgreSQL)" "plain" "plain"
