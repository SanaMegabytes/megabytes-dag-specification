#!/usr/bin/env bash
set -euo pipefail

CLI="../megabytes-cli"
NETWORK="-regtest"
RPCUSER="megabytesrpc"
RPCPASS="pass"

# Map ns -> datadir/rpcport
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

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need sudo
need ip
need jq

mcli() {
  local ns="$1"; shift
  local datadir="${NS_DATADIR[$ns]}"
  local rpcport="${NS_RPCPORT[$ns]}"
  sudo ip netns exec "$ns" "$CLI" \
    "$NETWORK" \
    -datadir="$datadir" \
    -rpcuser="$RPCUSER" \
    -rpcpassword="$RPCPASS" \
    -rpcconnect=127.0.0.1 \
    -rpcport="$rpcport" \
    "$@"
}

short() { echo "${1:-}" | cut -c1-12; }
line() { printf '%*s\n' 96 '' | tr ' ' '='; }

# Tunables (keep <= 10)
ISO_MINE="${ISO_MINE:-6}"      # blocks mined by isolated node (mgb2)
MAIN_MINE="${MAIN_MINE:-7}"    # blocks mined by the main side (mgb1)
# If MAIN_MINE > ISO_MINE, reorg depth on reconnect ~= ISO_MINE (safe).
# If ISO_MINE > MAIN_MINE, main side may reorg (avoid).
# Keep both <= 10 per your limit.

NETDEV="veth-mgb2"  # adjust if your netns veth name differs

# Find the interface inside mgb2 namespace automatically (fallback to NETDEV)
find_if_in_ns() {
  local ns="$1"
  # pick first non-lo interface that is UP
  local iface
  iface="$(sudo ip netns exec "$ns" ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')"
  echo "${iface:-$NETDEV}"
}

disconnect_mgb2() {
  local ifc
  ifc="$(find_if_in_ns mgb2)"
  echo ">> Partition: disconnect mgb2 (iface=$ifc)"
  # drop all traffic quickly by bringing link down
  sudo ip netns exec mgb2 ip link set dev "$ifc" down || true
}

reconnect_mgb2() {
  local ifc
  ifc="$(find_if_in_ns mgb2)"
  echo ">> Partition: reconnect mgb2 (iface=$ifc)"
  sudo ip netns exec mgb2 ip link set dev "$ifc" up || true
}

mine_n() {
  local ns="$1" n="$2"
  local addr
  addr="$(mcli "$ns" getnewaddress)"
  mcli "$ns" generatetoaddress "$n" "$addr" >/dev/null
}

snapshot() {
  local ns="$1"
  local bci tip h cw
  bci="$(mcli "$ns" getblockchaininfo)"
  tip="$(echo "$bci" | jq -r '.bestblockhash')"
  h="$(echo "$bci" | jq -r '.blocks')"
  cw="$(echo "$bci" | jq -r '.chainwork')"
  printf "%-4s h=%-5s tip=%s cw=..%s\n" "$ns" "$h" "$(short "$tip")" "${cw: -6}"
}

echo "09 partition test (safe reorg <= 10)"
line
echo "Initial state:"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4

base_tip="$(mcli mgb1 getbestblockhash)"
echo "Base tip (mgb1): $(short "$base_tip")"
line

disconnect_mgb2
sleep 0.5

echo "Mining on MAIN side (mgb1) +$MAIN_MINE blocks..."
mine_n mgb1 "$MAIN_MINE"
sleep 0.5
echo "Mining on ISOLATED side (mgb2) +$ISO_MINE blocks..."
mine_n mgb2 "$ISO_MINE"
sleep 0.5

line
echo "During partition (expected divergence):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4

echo
echo "Run diag now (optional): ./08_diag_divergence.sh"
line

reconnect_mgb2
sleep 1.5

line
echo "After reconnect (give it a moment):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4

echo
echo "Now run: ./08_diag_divergence.sh"
echo "If not converged yet, wait 2-3s and run again."
line

echo "Notes:"
echo "- With MAIN_MINE=$MAIN_MINE and ISO_MINE=$ISO_MINE, reorg depth should stay <= $ISO_MINE."
echo "- Keep both <= 10 as requested."