#!/usr/bin/env bash
set -euo pipefail

CLI="../megabytes-cli"
NETWORK="-regtest"
RPCUSER="megabytesrpc"
RPCPASS="pass"

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

LAST_N="${LAST_N:-10}"     # export LAST_N=20 pour plus
RANDOM_CHECKS="${RANDOM_CHECKS:-3}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need jq
need sudo
need ip

short() { echo "$1" | cut -c1-12; }
line() { printf '%*s\n' "${1:-96}" '' | tr ' ' '='; }

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

get_last_hashes() {
  local ns="$1" n="$2"
  local h prev i
  h="$(mcli "$ns" getbestblockhash)"
  for ((i=0; i<n; i++)); do
    echo "$h"
    prev="$(mcli "$ns" getblockheader "$h" | jq -r '.previousblockhash // empty')"
    [[ -z "$prev" ]] && break
    h="$prev"
  done
}

get_summary() {
  local ns="$1"
  local bci best blocks headers ibd cw
  bci="$(mcli "$ns" getblockchaininfo)"
  best="$(echo "$bci" | jq -r '.bestblockhash')"
  blocks="$(echo "$bci" | jq -r '.blocks')"
  headers="$(echo "$bci" | jq -r '.headers')"
  ibd="$(echo "$bci" | jq -r '.initialblockdownload')"
  cw="$(echo "$bci" | jq -r '.chainwork')"
  printf "%-4s  h=%-5s  headers=%-5s  ibd=%-5s  tip=%s  cw=%s\n" \
    "$ns" "$blocks" "$headers" "$ibd" "$(short "$best")" "$(short "$cw")"
}

chaintips_quick() {
  local ns="$1"
  mcli "$ns" getchaintips | jq -c '.[0:6] | map({height, hash:(.hash|.[0:12]), branchlen, status})'
}

block_fingerprint() {
  local ns="$1" hash="$2"
  mcli "$ns" getblockheader "$hash" | jq -r '[.height, .hash, (.pow_algo_id // "?"), (.pow_algo // "?"), .chainwork] | @tsv'
}

echo "Checking NOW: sync + dual-miner outcome"
line
echo "== Node summaries =="
declare -A TIP=() HEIGHT=() CW=() HEADERS=()
for ns in mgb1 mgb2 mgb3 mgb4; do
  out="$(mcli "$ns" getblockchaininfo)"
  TIP["$ns"]="$(echo "$out" | jq -r '.bestblockhash')"
  HEIGHT["$ns"]="$(echo "$out" | jq -r '.blocks')"
  HEADERS["$ns"]="$(echo "$out" | jq -r '.headers')"
  CW["$ns"]="$(echo "$out" | jq -r '.chainwork')"
  get_summary "$ns"
done

line
echo "== Convergence (same tip?) =="
base="${TIP[mgb1]}"
ok="YES"
for ns in mgb2 mgb3 mgb4; do
  [[ "${TIP[$ns]}" == "$base" ]] || ok="NO"
done
if [[ "$ok" == "YES" ]]; then
  echo "OK: all 4 nodes on same tip: $(short "$base") (h=${HEIGHT[mgb1]})"
else
  echo "FAIL: tips differ:"
  for ns in mgb1 mgb2 mgb3 mgb4; do
    echo "  $ns tip=$(short "${TIP[$ns]}") h=${HEIGHT[$ns]} cw=$(short "${CW[$ns]}") headers=${HEADERS[$ns]}"
  done
fi

line
echo "== Compare last $LAST_N block hashes (tip->backward) =="
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for ns in mgb1 mgb2 mgb3 mgb4; do
  get_last_hashes "$ns" "$LAST_N" > "$tmpdir/$ns.last"
done

# Compare lists
same_last="YES"
for ns in mgb2 mgb3 mgb4; do
  if ! diff -q "$tmpdir/mgb1.last" "$tmpdir/$ns.last" >/dev/null; then
    same_last="NO"
  fi
done

if [[ "$same_last" == "YES" ]]; then
  echo "OK: last $LAST_N blocks identical on all nodes."
else
  echo "FAIL: last $LAST_N differ. Showing first mismatch lines:"
  for ns in mgb2 mgb3 mgb4; do
    if ! diff -q "$tmpdir/mgb1.last" "$tmpdir/$ns.last" >/dev/null; then
      echo "---- diff mgb1 vs $ns ----"
      diff -u "$tmpdir/mgb1.last" "$tmpdir/$ns.last" | sed -n '1,120p'
    fi
  done
fi

line
echo "== Random spot-check (from last $LAST_N) =="
# pick 3 hashes from mgb1 list: 1st, middle, last (deterministic)
mapfile -t LST < "$tmpdir/mgb1.last"
len="${#LST[@]}"
if (( len == 0 )); then
  echo "No blocks?"
  exit 2
fi

idx1=0
idx2=$((len/2))
idx3=$((len-1))
pick=("$idx1" "$idx2" "$idx3")

for idx in "${pick[@]}"; do
  h="${LST[$idx]}"
  echo "Block $(short "$h"):"
  for ns in mgb1 mgb2 mgb3 mgb4; do
    fp="$(block_fingerprint "$ns" "$h" 2>/dev/null || true)"
    if [[ -n "$fp" ]]; then
      # height hash algo_id algo chainwork
      echo "  $ns  $(echo "$fp" | awk -F'\t' '{printf("height=%s algo=%s cw=%s\n",$1,$4,substr($5,1,12))}')"
    else
      echo "  $ns  MISSING (does not have this block)"
    fi
  done
done

line
echo "== Quick chaintips (top 6) =="
for ns in mgb1 mgb2 mgb3 mgb4; do
  echo "[$ns] $(chaintips_quick "$ns")"
done

line
if [[ "$ok" == "YES" && "$same_last" == "YES" ]]; then
  echo "RESULT: ✅ PASS (all synced; last blocks match)."
else
  echo "RESULT: ❌ FAIL (not fully synced / history differs)."
  echo "Hint: if FAIL but heights equal, it can be a tie/fork not resolved; mine 1-2 blocks on one node, or check why ActivateBestChain isn't switching."
fi