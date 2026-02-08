#!/usr/bin/env bash
# File: 05_stop.sh
# Stops megabytesd in namespaces mgb1..mgb4 and optionally clears netem + deletes namespaces/bridge.
#
# Usage:
#   ./05_stop.sh stop          # stop nodes only
#   ./05_stop.sh stopclear     # stop nodes + clear tc netem
#   ./05_stop.sh cleanup       # stop + clear + delete namespaces + delete bridge
#
set -euo pipefail

NS_LIST=(mgb1 mgb2 mgb3 mgb4)

CLI="../megabytes-cli"
AUTH=(-regtest -rpcuser=megabytesrpc -rpcpassword=pass)

declare -A NS_DATADIR=(
  [mgb1]="/tmp/mgb-node1"
  [mgb2]="/tmp/mgb-node2"
  [mgb3]="/tmp/mgb-node3"
  [mgb4]="/tmp/mgb-node4"
)

declare -A NS_RPCPORT=(
  [mgb1]="8332"
  [mgb2]="8333"
  [mgb3]="8334"
  [mgb4]="8335"
)

iface_for_ns() {
  case "$1" in
    mgb1) echo "veth1" ;;
    mgb2) echo "veth2" ;;
    mgb3) echo "veth3" ;;
    mgb4) echo "veth4" ;;
    *) echo "unknown" ;;
  esac
}

stop_node() {
  local ns="$1"
  local datadir="${NS_DATADIR[$ns]}"
  local rpcport="${NS_RPCPORT[$ns]}"

  echo "[$ns] stopping..."
  # try RPC stop first
  sudo ip netns exec "$ns" "$CLI" "${AUTH[@]}" -datadir="$datadir" -rpcport="$rpcport" stop 2>/dev/null || true

  # give it a moment
  sleep 0.2

  # if still running, kill it (best effort)
  sudo ip netns exec "$ns" bash -lc "pkill -f '[m]egabytesd.*-datadir=$datadir' 2>/dev/null || true"
  sudo ip netns exec "$ns" bash -lc "pkill -f '[m]egabytesd.*-rpcport=$rpcport' 2>/dev/null || true"
  echo "[$ns] stopped"
}

clear_tc() {
  local ns="$1"
  local dev
  dev="$(iface_for_ns "$ns")"
  [[ "$dev" == "unknown" ]] && return 0
  sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
  echo "[$ns] tc cleared"
}

cleanup_netns() {
  local ns="$1"
  sudo ip netns del "$ns" 2>/dev/null || true
  echo "[$ns] netns deleted"
}

MODE="${1:-stop}"

case "$MODE" in
  stop|stopclear|cleanup)
    ;;
  *)
    echo "Usage: ./05_stop.sh stop|stopclear|cleanup" >&2
    exit 1
    ;;
esac

for ns in "${NS_LIST[@]}"; do
  # namespace might not exist (best effort)
  if sudo ip netns list | grep -q "^$ns\b"; then
    stop_node "$ns"
  else
    echo "[$ns] not found, skipping stop"
  fi
done

if [[ "$MODE" == "stopclear" || "$MODE" == "cleanup" ]]; then
  for ns in "${NS_LIST[@]}"; do
    if sudo ip netns list | grep -q "^$ns\b"; then
      clear_tc "$ns"
    fi
  done
fi

if [[ "$MODE" == "cleanup" ]]; then
  # delete namespaces
  for ns in "${NS_LIST[@]}"; do
    if sudo ip netns list | grep -q "^$ns\b"; then
      cleanup_netns "$ns"
    fi
  done

  # delete bridge (if you used mgbbr0 in 01_net_setup.sh)
  sudo ip link del mgbbr0 2>/dev/null || true
  echo "[bridge] mgbbr0 deleted"
fi

echo "OK: $MODE done"