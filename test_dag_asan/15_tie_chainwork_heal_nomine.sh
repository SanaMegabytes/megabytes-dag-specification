#!/usr/bin/env bash
set -euo pipefail

# 15_tie_chainwork_heal_nomine.sh
# Tie-chainwork fork + heal(no-mine) + then mine 1 to break tie
# Requires: netns setup + your daemons already running
# Uses: 04_badnet.sh to partition/heal

CLI="$HOME/megabytes/build/src/megabytes-cli"
BADNET="./04_badnet.sh"

NETWORK="-regtest"
RPCUSER="megabytesrpc"
RPCPASS="pass"

declare -A DD=(
  [mgb1]="/tmp/mgb-node1"
  [mgb2]="/tmp/mgb-node2"
  [mgb3]="/tmp/mgb-node3"
  [mgb4]="/tmp/mgb-node4"
)
declare -A RP=(
  [mgb1]="8332"
  [mgb2]="8333"
  [mgb3]="8334"
  [mgb4]="8335"
)

IP_MGB1="10.10.0.11"
P2P_MGB1="10000"
IP_MGB2="10.10.0.12"
P2P_MGB2="20000"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need sudo
need ip
need jq

mcli() {
  local ns="$1"; shift
  sudo ip netns exec "$ns" "$CLI" \
    "$NETWORK" \
    -datadir="${DD[$ns]}" \
    -rpcuser="$RPCUSER" \
    -rpcpassword="$RPCPASS" \
    -rpcconnect=127.0.0.1 \
    -rpcport="${RP[$ns]}" \
    "$@"
}

short(){ echo "${1:-}" | cut -c1-12; }
line(){ printf '%*s\n' 96 '' | tr ' ' '='; }

WAIT_SECS="${WAIT_SECS:-60}"          # wait after heal (no-mine)
POST_TIE_MINE="${POST_TIE_MINE:-1}"   # mine 1 block to break tie
NET_MINE="${NET_MINE:-6}"            # IMPORTANT: make equal work both sides
ISO_MINE="${ISO_MINE:-6}"            # IMPORTANT: equals NET_MINE for tie

wallet_for_ns() {
  case "$1" in
    mgb1) echo "t1" ;;
    mgb2) echo "t2" ;;
    mgb3) echo "t3" ;;
    mgb4) echo "t4" ;;
    *) echo "tX" ;;
  esac
}

ensure_wallet_loaded() {
  local ns="$1"
  local w; w="$(wallet_for_ns "$ns")"
  echo ">> [$ns] ensure wallet loaded: $w"
  mcli "$ns" loadwallet "$w" >/dev/null 2>&1 || true
}

snapshot() {
  local ns="$1"
  local h tip hdr cw mp
  h="$(mcli "$ns" getblockcount)"
  tip="$(mcli "$ns" getbestblockhash)"
  hdr="$(mcli "$ns" getblockheader "$tip" true)"
  cw="$(echo "$hdr" | jq -r '.chainwork')"
  mp="$(mcli "$ns" getmempoolinfo | jq -r '.size')"
  printf "%-4s h=%-5s mp=%-5s tip=%s cw=..%s\n" "$ns" "$h" "$mp" "$(short "$tip")" "${cw: -6}"
}

mine_n() {
  local ns="$1" n="$2"
  local addr
  addr="$(mcli "$ns" getnewaddress)"
  mcli "$ns" generatetoaddress "$n" "$addr" >/dev/null
}

connect_mgb2_onetry() {
  mcli mgb2 addnode "${IP_MGB1}:${P2P_MGB1}" onetry >/dev/null 2>&1 || true
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

get_cw_suffix() {
  local ns="$1"
  local tip hdr cw
  tip="$(mcli "$ns" getbestblockhash)"
  hdr="$(mcli "$ns" getblockheader "$tip" true)"
  cw="$(echo "$hdr" | jq -r '.chainwork')"
  echo "${cw: -6}"
}

echo "15 tie-chainwork + heal(no-mine) + then mine 1 to break tie [NETNS + ASAN daemons]"
line
echo "Pre-state:"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

echo ">> Ensure wallets loaded"
ensure_wallet_loaded mgb1
ensure_wallet_loaded mgb2
ensure_wallet_loaded mgb3
ensure_wallet_loaded mgb4
line

echo ">> Apply badnet: insane on mgb1/3/4 + PARTITION on mgb2"
"$BADNET" insane mgb1
"$BADNET" insane mgb3
"$BADNET" insane mgb4
"$BADNET" partition mgb2
"$BADNET" status || true
line

echo "Phase A: Mine equal-work forks (TIE) while mgb2 partitioned"
echo ">> network side mine on mgb1: NET_MINE=$NET_MINE"
mine_n mgb1 "$NET_MINE"
echo ">> isolated side mine on mgb2: ISO_MINE=$ISO_MINE"
mine_n mgb2 "$ISO_MINE"

line
echo "During isolation (expect different tips, but SAME cw suffix often):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

CW1="$(get_cw_suffix mgb1)"
CW2="$(get_cw_suffix mgb2)"
echo ">> chainwork suffix during isolation: mgb1..$CW1 mgb2..$CW2"
if [[ "$CW1" != "$CW2" ]]; then
  echo "⚠️ Not a tie (CW differs). Re-run with NET_MINE==ISO_MINE and ensure no extra mining happened."
fi
line

echo "Phase B: Heal mgb2 WITHOUT mining; tie means converge is NOT guaranteed"
"$BADNET" heal mgb2
sleep 1
connect_mgb2_onetry

echo "After heal (waiting up to ${WAIT_SECS}s):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4

if wait_converge "$WAIT_SECS"; then
  echo "⚠️ Unexpected: converged even under tie (could be tie-breaker or tip-score not purely CW)."
else
  echo "✅ Expected: not converged under tie (no deterministic winner without new info)."
fi
line

echo "Phase C: Break tie by mining ${POST_TIE_MINE} block(s) on network side (mgb1)"
mine_n mgb1 "$POST_TIE_MINE"
sleep 2
wait_converge "$WAIT_SECS" || true

line
echo "Post:"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

echo ">> Cleanup badnet (optional)"
echo "Try: $BADNET clear all"
echo "PASS criteria: tie observed (often no converge) then 1 block breaks tie and convergence occurs."
line
