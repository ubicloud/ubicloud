#!/bin/bash
# Put a remote-stripe-server's namespace one emulated network hop away:
#
#   rtt_link.sh up <delay>   netns clrtt at 10.253.0.2, host end 10.253.0.1,
#                            netem <delay> on both ends of the veth
#   rtt_link.sh down
#
# probe_remote_connections.rb dials it with SERVER_NETNS=clrtt
# SERVER_ADDRESS=10.253.0.2.
set -euo pipefail
NS=clrtt; H=vrtth; N=vrttn
down() { ip netns del $NS 2>/dev/null || true; ip link del $H 2>/dev/null || true; }
case "${1:-}" in
  up)
    DELAY=${2:?usage: rtt_link.sh up <delay, e.g. 250us>}
    down
    ip netns add $NS
    ip link add $H type veth peer name $N
    ip link set $N netns $NS
    ip addr add 10.253.0.1/30 dev $H
    ip link set $H up
    ip netns exec $NS ip addr add 10.253.0.2/30 dev $N
    ip netns exec $NS ip link set $N up
    ip netns exec $NS ip link set lo up
    tc qdisc add dev $H root netem delay "$DELAY"
    ip netns exec $NS tc qdisc add dev $N root netem delay "$DELAY"
    echo "netem delay $DELAY on $H and $NS/$N"
    ping -c 20 -i 0.05 -q 10.253.0.2 | tail -1
    ;;
  down) down ;;
  *) echo "usage: rtt_link.sh up <delay> | down" >&2; exit 1 ;;
esac
