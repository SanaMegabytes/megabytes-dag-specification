#!/usr/bin/env bash
set -euo pipefail

CLI="../megabytes-cli"
NETWORK="-regtest"
RPCUSER="megabytesrpc"
RPCPASS="pass"

# ns -> datadir/rpcport
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

# Tunables (keep <=10)
A_MINE="${A_MINE:-6}"   # blocks mined on side A (mgb1 + mgb2)
B_MINE="${B_MINE:-5}"   # blocks mined on side B (mgb3 + mgb4)
WAIT_SECS="${WAIT_SECS:-25}"

# IPs / ports (match your setup)
IP_MGB1="10.10.0.11"
IP_MGB3="10.10.0.13"
IP_MGB4="10.10.0.14"
P2P_MGB3="30000"
P2P_MGB4="40000"

# Try to detect interface inside namespace
find_if_in_ns() {
  local ns="$1"
  sudo ip netns exec "$ns" ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}'
}

# --- netem cleanup helper (optional but safe) ---
clear_netem() {
  local ns="$1"
  local ifc
  ifc="$(find_if_in_ns "$ns" || true)"
  [[ -n "${ifc:-}" ]] || return 0
  sudo ip netns exec "$ns" tc qdisc del dev "$ifc" root 2>/dev/null || true
}

# --- Partial partition rules (mgb2 can't talk to mgb3/mgb4) ---
apply_rules() {
  echo ">> Apply partial partition: mgb2 BLOCK <-> (mgb3,mgb4) on P2P"
  # Flush and set baseline policy to ACCEPT
  sudo ip netns exec mgb2 iptables -F
  sudo ip netns exec mgb2 iptables -P INPUT ACCEPT
  sudo ip netns exec mgb2 iptables -P OUTPUT ACCEPT
  sudo ip netns exec mgb2 iptables -P FORWARD ACCEPT

  # Block OUTPUT from mgb2 to mgb3/mgb4 P2P ports
  sudo ip netns exec mgb2 iptables -A OUTPUT -p tcp -d "$IP_MGB3" --dport "$P2P_MGB3" -j DROP
  sudo ip netns exec mgb2 iptables -A OUTPUT -p tcp -d "$IP_MGB4" --dport "$P2P_MGB4" -j DROP

  # Block INPUT to mgb2 from mgb3/mgb4 (their P2P source ports)
  sudo ip netns exec mgb2 iptables -A INPUT  -p tcp -s "$IP_MGB3" --sport "$P2P_MGB3" -j DROP
  sudo ip netns exec mgb2 iptables -A INPUT  -p tcp -s "$IP_MGB4" --sport "$P2P_MGB4" -j DROP

  echo ">> Rules active (mgb2 still can talk to mgb1)"
}

clear_rules() {
  echo ">> Clear iptables rules in mgb2 (restore open)"
  sudo ip netns exec mgb2 iptables -F || true
  sudo ip netns exec mgb2 iptables -P INPUT ACCEPT || true
  sudo ip netns exec mgb2 iptables -P OUTPUT ACCEPT || true
  sudo ip netns exec mgb2 iptables -P FORWARD ACCEPT || true
}

trap 'clear_rules' EXIT

snapshot() {
  local ns="$1"
  local bci tip h cw
  bci="$(mcli "$ns" getblockchaininfo)"
  tip="$(echo "$bci" | jq -r '.bestblockhash')"
  h="$(echo "$bci" | jq -r '.blocks')"
  cw="$(echo "$bci" | jq -r '.chainwork')"
  printf "%-4s h=%-5s tip=%s cw=..%s\n" "$ns" "$h" "$(short "$tip")" "${cw: -6}"
}

mine_n() {
  local ns="$1" n="$2"
  local addr
  addr="$(mcli "$ns" getnewaddress)"
  mcli "$ns" generatetoaddress "$n" "$addr" >/dev/null
}

wait_converge() {
  local max="$1"
  for ((i=1;i<=max;i++)); do
    local t1 t2 t3 t4
    t1="$(mcli mgb1 getbestblockhash)"
    t2="$(mcli mgb2 getbestblockhash)"
    t3="$(mcli mgb3 getbestblockhash)"
    t4="$(mcli mgb4 getbestblockhash)"
    if [[ "$t1" == "$t2" && "$t1" == "$t3" && "$t1" == "$t4" ]]; then
      echo "✅ Converged after ${i}s: $(short "$t1")"
      return 0
    fi
    sleep 1
  done
  echo "⚠️ Not converged after ${max}s"
  return 1
}

echo "10 partial partition test (mgb2 isolated from mgb3/mgb4; netns-aware)"
line
echo "Initial state:"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

# Optional: clear netem on mgb2 so this test isolates *only* via iptables
# (comment out if you WANT netem too)
clear_netem mgb2

apply_rules
sleep 1

echo "Mining Side A (mgb1 + mgb2) total +$A_MINE blocks (mine on mgb1 only)"
mine_n mgb1 "$A_MINE"

echo "Mining Side B (mgb3 + mgb4) total +$B_MINE blocks (mine on mgb3 only)"
mine_n mgb3 "$B_MINE"

line
echo "During partial partition (expected divergence):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
echo
echo "Run now (optional): ./08_diag_divergence.sh"
line

echo ">> Removing rules (reconnect full mesh)"
clear_rules
sleep 1

line
echo "After reconnect (waiting up to ${WAIT_SECS}s for convergence):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
wait_converge "$WAIT_SECS" || true

echo
echo "Now run: ./08_diag_divergence.sh"
line
echo "Notes:"
echo "- A_MINE=$A_MINE, B_MINE=$B_MINE (keep <=10)."
echo "- If you had netem active, this script clears it on mgb2 by default."
echo "- If convergence is slow, increase WAIT_SECS or keep netem off."