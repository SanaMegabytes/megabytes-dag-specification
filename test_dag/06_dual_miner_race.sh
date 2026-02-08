#!/usr/bin/env bash
set -euo pipefail

# File: 06_dual_miner_race.sh
# Goal: Realistic "race" without full partition:
# - Keep the network connected but degraded (hard/medium/clear)
# - Mine X blocks on one node and Y blocks on another node (overlapping in time)
# - Verify everyone converges to the same tip
#
# Usage:
#   VERBOSE=1 ./06_dual_miner_race.sh [net_profile=hard] [minerA=mgb1] [a_blocks=3] [minerB=mgb2] [b_blocks=2]
#
# Example:
#   VERBOSE=1 ./06_dual_miner_race.sh hard mgb1 3 mgb2 2

net_profile="${1:-hard}"
minerA="${2:-mgb1}"
a_blocks="${3:-3}"
minerB="${4:-mgb2}"
b_blocks="${5:-2}"

# RPC mapping
declare -A RPCPORT=( [mgb1]=8332 [mgb2]=8333 [mgb3]=8334 [mgb4]=8335 )
declare -A DATADIR=( [mgb1]=/tmp/mgb-node1 [mgb2]=/tmp/mgb-node2 [mgb3]=/tmp/mgb-node3 [mgb4]=/tmp/mgb-node4 )

VERBOSE="${VERBOSE:-0}"

cli() {
  local ns="$1"; shift
  sudo ip netns exec "$ns" ../megabytes-cli -regtest \
    -rpcuser=megabytesrpc -rpcpassword=pass \
    -rpcport="${RPCPORT[$ns]}" -datadir="${DATADIR[$ns]}" "$@"
}

best()   { cli "$1" getbestblockhash; }
height() { cli "$1" getblockcount; }

snap_one() {
  local ns="$1"
  local b h
  b="$(best "$ns")"
  h="$(height "$ns")"
  echo "--- $ns ---"
  echo "best=$b height=$h"
  if [[ "$VERBOSE" == "1" ]]; then
    echo "[blockchaininfo]"
    cli "$ns" getblockchaininfo
    echo "[mempoolinfo]"
    cli "$ns" getmempoolinfo
    echo "[chaintips]"
    cli "$ns" getchaintips
    echo "[peers]"
    echo "[$ns] connections=$(cli "$ns" getconnectioncount)"
    # show a few useful peer fields
    cli "$ns" getpeerinfo | grep -E '"addr"|inbound|pingtime|synced_headers|synced_blocks|inflight|startingheight' | head -n 120 || true
  fi
}

snapshot() {
  local label="$1"
  echo "========== SNAPSHOT: $label =========="
  for n in mgb1 mgb2 mgb3 mgb4; do
    snap_one "$n"
  done
  echo "===================================="
}

mine_blocks() {
  local ns="$1" n="$2"
  local addr
  addr="$(cli "$ns" getnewaddress)"
  for ((i=0;i<n;i++)); do
    cli "$ns" generatetoaddress 1 "$addr" >/dev/null
    # jitter 50-250ms
    python3 - <<'PY'
import random, time
time.sleep(random.uniform(0.05, 0.25))
PY
  done
}

tail_logs() {
  local ns="$1"
  local f="${DATADIR[$ns]}/regtest/debug.log"
  echo "---- tail $ns ($f) ----"
  tail -n 80 "$f" | grep -E 'finality|reorg|DisconnectBlock|ConnectBlock|ActivateBestChain|Invalid|error|Reject|mgbdag|MGB-DAG-FETCH|DAGP\[connect\]|SelectParent_GhostDAG|UpdateTip|Misbehaving|ban' || true
  # if grep finds nothing, still show last lines
  if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    tail -n 40 "$f" || true
  fi
}

# --- Network profile ---
echo "== Applying network profile: $net_profile to all =="
if [[ "$net_profile" == "clear" ]]; then
  ./04_badnet.sh clear all
else
  ./04_badnet.sh "$net_profile" all
fi

snapshot "baseline"

echo "== Race mining (no partition): $minerA mines $a_blocks, $minerB mines $b_blocks =="

# Start minerA slightly before minerB to maximize overlap and chances of short forks
mine_blocks "$minerA" "$a_blocks" &
pidA=$!
sleep 0.25
mine_blocks "$minerB" "$b_blocks" &
pidB=$!

wait "$pidA"
wait "$pidB"

snapshot "after-mining"

echo "== Waiting for convergence (up to 40s) =="
ok=0
for i in {1..40}; do
  h1="$(best mgb1)"
  h2="$(best mgb2)"
  h3="$(best mgb3)"
  h4="$(best mgb4)"
  if [[ "$h1" == "$h2" && "$h1" == "$h3" && "$h1" == "$h4" ]]; then
    ok=1
    echo "Converged at t=$i s : $h1"
    break
  fi
  sleep 1
done

if [[ "$ok" -ne 1 ]]; then
  echo "!! DID NOT CONVERGE within 40s"
  echo "Best hashes: mgb1=$h1 mgb2=$h2 mgb3=$h3 mgb4=$h4"
  echo "== Quick chaintips =="
  for n in mgb1 mgb2 mgb3 mgb4; do
    echo "-- $n --"
    cli "$n" getchaintips || true
  done
  echo "== Tail logs for hints =="
  tail_logs mgb1
  tail_logs mgb2
  tail_logs mgb3
  tail_logs mgb4
  exit 2
fi

echo "== Chain tips (mgb1 / $minerA / $minerB) =="
cli mgb1 getchaintips
cli "$minerA" getchaintips
cli "$minerB" getchaintips

if [[ "$VERBOSE" == "1" ]]; then
  echo "== Tip headers (mgb1 + $minerA + $minerB) =="
  tip="$(best mgb1)"
  echo "--- mgb1 tip header ---"; cli mgb1 getblockheader "$tip"
  echo "--- $minerA tip header ---"; cli "$minerA" getblockheader "$tip"
  echo "--- $minerB tip header ---"; cli "$minerB" getblockheader "$tip"

  echo "== Tail logs at end (focus on accept/reject/reorg/finality) =="
  tail_logs mgb1
  tail_logs "$minerA"
  tail_logs "$minerB"
fi

echo "== OK: dual miner race test passed =="
exit 0