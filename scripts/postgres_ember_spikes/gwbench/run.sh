#!/bin/bash
# Compare a Go and a Ruby TLS-splicing gateway on the same host.
set -uo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
UP=127.0.0.1:7001
GW=127.0.0.1:7443

if [[ ! -f cert.pem ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout key.pem \
    -out cert.pem -days 365 -nodes -subj "/CN=gwbench" >/dev/null 2>&1
fi
$GO build -o upstream upstream.go && $GO build -o gateway-go gateway.go && $GO build -o client client.go

pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

./upstream $UP & pids+=($!); sleep 1

rss_of() { awk '/VmRSS/ {print $2}' /proc/$1/status 2>/dev/null; }
cpu_of() { awk '{print ($14+$15)}' /proc/$1/stat 2>/dev/null; }

bench() {
  local name=$1 pid=$2
  echo "### $name ###"
  for spec in "latency 64 50" "latency 64 200" "throughput 1048576 20" "throughput 1048576 100"; do
    set -- $spec
    local mode=$1 size=$2 conns=$3
    local c0=$(cpu_of $pid)
    local out=$(./client -addr $GW -mode $mode -size $size -conns $conns -duration 10s)
    local c1=$(cpu_of $pid)
    local cpu=$(echo "scale=2; ($c1 - $c0) / 100 / 10 * 100" | bc)
    echo "  $mode size=$size conns=$conns  $out  gateway_cpu=${cpu}%"
  done
  ./client -addr $GW -mode idle -conns 500 > /tmp/idle.json &
  local cpid=$!
  sleep 8
  echo "  idle 500 connections: gateway RSS = $(rss_of $pid) kB  ($(cat /tmp/idle.json 2>/dev/null))"
  kill $cpid 2>/dev/null; wait $cpid 2>/dev/null
  sleep 2
}

./gateway-go $GW $UP & GOPID=$!; pids+=($GOPID); sleep 1
bench "GO gateway" $GOPID
kill $GOPID 2>/dev/null; wait $GOPID 2>/dev/null; sleep 1

ruby gateway.rb $GW $UP & RBPID=$!; pids+=($RBPID); sleep 2
bench "RUBY gateway" $RBPID
kill $RBPID 2>/dev/null
