#!/usr/bin/env bash
set -euo pipefail

CLI="../megabytes-cli"
DAEMON="../megabytesd"
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

# P2P addressing (match your setup)
IP_MGB1="10.10.0.11"
IP_MGB2="10.10.0.12"
IP_MGB3="10.10.0.13"
IP_MGB4="10.10.0.14"
P2P_MGB1="10000"
P2P_MGB2="20000"
P2P_MGB3="30000"
P2P_MGB4="40000"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need sudo
need ip
need jq
need timeout
need pgrep

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
A_MINE="${A_MINE:-6}"        # mine on mgb1 (side A)
B_MINE="${B_MINE:-5}"        # mine on mgb3 (side B)
WAIT_SECS="${WAIT_SECS:-30}"
RESTART_WAIT="${RESTART_WAIT:-20}"   # how long to wait mgb2 to come back

find_if_in_ns() {
  local ns="$1"
  sudo ip netns exec "$ns" ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}'
}

clear_netem() {
  local ns="$1"
  local ifc
  ifc="$(find_if_in_ns "$ns" || true)"
  [[ -n "${ifc:-}" ]] || return 0
  sudo ip netns exec "$ns" tc qdisc del dev "$ifc" root 2>/dev/null || true
}

apply_partial_partition_rules_mgb2() {
  echo ">> Apply partial partition: mgb2 BLOCK <-> (mgb3,mgb4) on P2P"
  sudo ip netns exec mgb2 iptables -F
  sudo ip netns exec mgb2 iptables -P INPUT ACCEPT
  sudo ip netns exec mgb2 iptables -P OUTPUT ACCEPT
  sudo ip netns exec mgb2 iptables -P FORWARD ACCEPT

  # block mgb2 <-> mgb3/mgb4 p2p
  sudo ip netns exec mgb2 iptables -A OUTPUT -p tcp -d "$IP_MGB3" --dport "$P2P_MGB3" -j DROP
  sudo ip netns exec mgb2 iptables -A OUTPUT -p tcp -d "$IP_MGB4" --dport "$P2P_MGB4" -j DROP
  sudo ip netns exec mgb2 iptables -A INPUT  -p tcp -s "$IP_MGB3" --sport "$P2P_MGB3" -j DROP
  sudo ip netns exec mgb2 iptables -A INPUT  -p tcp -s "$IP_MGB4" --sport "$P2P_MGB4" -j DROP

  echo ">> Rules active (mgb2 still can talk to mgb1)"
}

clear_rules_mgb2() {
  echo ">> Clear iptables rules in mgb2 (restore open)"
  sudo ip netns exec mgb2 iptables -F || true
  sudo ip netns exec mgb2 iptables -P INPUT ACCEPT || true
  sudo ip netns exec mgb2 iptables -P OUTPUT ACCEPT || true
  sudo ip netns exec mgb2 iptables -P FORWARD ACCEPT || true
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

mine_n() {
  local ns="$1" n="$2"
  local addr
  addr="$(mcli "$ns" getnewaddress)"
  mcli "$ns" generatetoaddress "$n" "$addr" >/dev/null
}

wait_rpc() {
  local ns="$1" max="$2"
  for ((i=1;i<=max;i++)); do
    if mcli "$ns" getblockchaininfo >/dev/null 2>&1; then
      echo "✅ RPC back after ${i}s ($ns)"
      return 0
    fi
    sleep 1
  done
  echo "⚠️ RPC not responding after ${max}s ($ns)"
  return 1
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

restart_mgb2_only() {
  local datadir="${NS_DATADIR[mgb2]}"
  local rpcport="${NS_RPCPORT[mgb2]}"

  echo ">> Restart mgb2 only (RPC stop -> relaunch megabytesd)"
  # graceful stop
  mcli mgb2 stop >/dev/null 2>&1 || true
  sleep 1

  # ensure process exited inside netns (best-effort)
  # kill leftover if any (avoid matching unrelated processes on host)
  sudo ip netns exec mgb2 bash -lc "pkill -f 'megabytesd.*-datadir=${datadir}'" 2>/dev/null || true
  sleep 1

  # relaunch with same args as your start script
  sudo ip netns exec mgb2 "$DAEMON" \
    -datadir="$datadir" \
    -bind="$IP_MGB2" \
    -port="$P2P_MGB2" \
    -rpcport="$rpcport" \
    -rpcuser="$RPCUSER" \
    -rpcpassword="$RPCPASS" \
    -rpcallowip=127.0.0.1 \
    -debug=net \
    -debug=mgbdag \
    -daemon \
    -regtest

  # wait rpc comes back
  wait_rpc mgb2 "$RESTART_WAIT"
}

spotcheck_dagmeta() {
  local ns="$1" h="$2"
  echo ">> [$ns] getdagmeta $(short "$h")"
  mcli "$ns" getdagmeta "$h" | jq '{hash,height,has_meta,sp_match,blue_score_match,blue_steps_match,flags:(.meta_db.flags_decoded // null)}'
}

connect_from_mgb2() {
  # Force mgb2 to actively dial peers (use onetry so it doesn't persist in config)
  # During partition, only mgb1 is reachable; after reconnect, mgb3/mgb4 too.
  local targets=("$@")
  for t in "${targets[@]}"; do
    mcli mgb2 addnode "$t" onetry >/dev/null 2>&1 || true
  done
}

trap 'clear_rules_mgb2' EXIT

echo "11 restart during partial partition (mgb2 only)"
line
echo "Initial state:"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

# Keep this test deterministic: remove netem on mgb2 by default
clear_netem mgb2

apply_partial_partition_rules_mgb2
sleep 1

echo "Mining Side A on mgb1 +$A_MINE"
mine_n mgb1 "$A_MINE"
echo "Mining Side B on mgb3 +$B_MINE"
mine_n mgb3 "$B_MINE"

line
echo "During partition (expected divergence):"
snapshot mgb1
snapshot mgb2 || echo "mgb2 rpc down? (unexpected before restart)"
snapshot mgb3
snapshot mgb4
line

echo ">> Restarting mgb2 while still partitioned (stress)"
restart_mgb2_only

line
echo "After mgb2 restart (still partitioned):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

echo ">> Reconnect full mesh (remove rules)"
clear_rules_mgb2
sleep 1

# ✅ important: force mgb2 to dial everyone again after rules cleared
connect_from_mgb2 \
  "${IP_MGB1}:${P2P_MGB1}" \
  "${IP_MGB3}:${P2P_MGB3}" \
  "${IP_MGB4}:${P2P_MGB4}"
wait_mgb2_has_peer 10 || true

line
echo "After reconnect (waiting up to ${WAIT_SECS}s for convergence):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
wait_converge "$WAIT_SECS" || true
line

# Spot-check DAG meta on the winning tip from mgb1
tip="$(mcli mgb1 getbestblockhash)"
spotcheck_dagmeta mgb2 "$tip" || true

echo
echo "Now run: ./08_diag_divergence.sh"
line