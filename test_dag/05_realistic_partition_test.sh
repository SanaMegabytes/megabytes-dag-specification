#!/usr/bin/env bash
set -euo pipefail

# Realistic fork test: isolate 1 node, mine a few blocks on both sides, heal, verify convergence.
# Verbose mode:
#   VERBOSE=1 TAILLOG=80 ./05_realistic_partition_test.sh mgb3 4 2 hard

isolated="${1:-mgb3}"
main_blocks="${2:-4}"        # 2-6 recommended
isolated_blocks="${3:-2}"    # 1-4 recommended
net_profile="${4:-hard}"     # hard/medium/clear

VERBOSE="${VERBOSE:-0}"
TAILLOG="${TAILLOG:-60}"

# RPC mapping
declare -A RPCPORT=( [mgb1]=8332 [mgb2]=8333 [mgb3]=8334 [mgb4]=8335 )
declare -A DATADIR=( [mgb1]=/tmp/mgb-node1 [mgb2]=/tmp/mgb-node2 [mgb3]=/tmp/mgb-node3 [mgb4]=/tmp/mgb-node4 )

cli() {
  local ns="$1"; shift
  sudo ip netns exec "$ns" ../megabytes-cli -regtest \
    -rpcuser=megabytesrpc -rpcpassword=pass \
    -rpcport="${RPCPORT[$ns]}" -datadir="${DATADIR[$ns]}" "$@"
}

best() { cli "$1" getbestblockhash; }

height_of() {
  local ns="$1"
  cli "$ns" getblockcount
}

tip_header() {
  local ns="$1"
  local h
  h="$(best "$ns")"
  cli "$ns" getblockheader "$h"
}

peer_summary() {
  local ns="$1"
  echo "[$ns] connections=$(cli "$ns" getconnectioncount)"
  # compact: addr + inbound + ping + startingheight
  cli "$ns" getpeerinfo \
    | grep -E '"addr":|"inbound":|"pingtime":|"startingheight":' \
    | head -n 60 || true
}

snapshot() {
  local tag="$1"
  echo "========== SNAPSHOT: $tag =========="
  for n in mgb1 mgb2 mgb3 mgb4; do
    echo "--- $n ---"
    echo "best=$(best "$n") height=$(height_of "$n")"
    if [[ "$VERBOSE" == "1" ]]; then
      echo "[blockchaininfo]"
      cli "$n" getblockchaininfo | head -n 80 || true
      echo "[mempoolinfo]"
      cli "$n" getmempoolinfo || true
      echo "[chaintips]"
      cli "$n" getchaintips || true
      echo "[peers]"
      peer_summary "$n"
    fi
  done
  echo "===================================="
}

tail_logs() {
  local ns="$1"
  local f="${DATADIR[$ns]}/regtest/debug.log"
  echo "---- tail $ns ($f) ----"
  sudo ip netns exec "$ns" bash -lc "test -f '$f' && tail -n '$TAILLOG' '$f' || echo '(no debug.log yet)'" || true
}

mine_blocks() {
  local ns="$1" n="$2"
  local addr
  addr="$(cli "$ns" getnewaddress)"
  cli "$ns" generatetoaddress "$n" "$addr" >/dev/null
}

echo "== Applying network profile: $net_profile to all =="
if [[ "$net_profile" == "clear" ]]; then
  ./04_badnet.sh clear all
else
  ./04_badnet.sh "$net_profile" all
fi

snapshot "baseline"

echo "== Partitioning $isolated =="
./04_badnet.sh partition "$isolated"

snapshot "after-partition"

echo "== Mine $main_blocks blocks on main side (mgb1) =="
mine_blocks mgb1 "$main_blocks"

echo "== Mine $isolated_blocks blocks on isolated side ($isolated) =="
mine_blocks "$isolated" "$isolated_blocks"

snapshot "before-heal"

echo "== Healing $isolated =="
./04_badnet.sh heal "$isolated"

if [[ "$VERBOSE" == "1" ]]; then
  echo "== Tail logs right after heal (to see accept/reject reasons) =="
  tail_logs mgb1
  tail_logs "$isolated"
fi

echo "== Waiting for convergence (up to 30s) =="
ok=0
for i in {1..30}; do
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

echo "== Chain tips (mgb1 / $isolated) =="
cli mgb1 getchaintips
cli "$isolated" getchaintips

if [[ "$VERBOSE" == "1" ]]; then
  echo "== Tip headers (mgb1 + isolated) =="
  echo "--- mgb1 tip header ---"; tip_header mgb1 || true
  echo "--- $isolated tip header ---"; tip_header "$isolated" || true
  echo "== Tail logs at end =="
  tail_logs mgb1
  tail_logs "$isolated"
fi

if [[ "$ok" -ne 1 ]]; then
  echo "!! DID NOT CONVERGE within 30s"
  echo "Best hashes: mgb1=$h1 mgb2=$h2 mgb3=$h3 mgb4=$h4"
  if [[ "$VERBOSE" == "1" ]]; then
    echo "== Extra chaintips all nodes =="
    for n in mgb1 mgb2 mgb3 mgb4; do
      echo "--- $n ---"
      cli "$n" getchaintips || true
      tail_logs "$n"
    done
  fi
  exit 2
fi

echo "== OK: realistic partition test passed =="
exit 0