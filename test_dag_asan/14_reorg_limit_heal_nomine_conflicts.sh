#!/usr/bin/env bash
set -euo pipefail

CLI="/home/**/megabytes/build/src/megabytes-cli"
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

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need sudo; need ip; need jq; need python3

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

chainwork_of() {
  local ns="$1"
  local tip hdr
  tip="$(mcli "$ns" getbestblockhash)"
  hdr="$(mcli "$ns" getblockheader "$tip" true)"
  echo "$hdr" | jq -r '.chainwork'
}

cw_gt() {
  local a="$1" b="$2"
  python3 - "$a" "$b" <<'PY'
import sys
a=int(sys.argv[1],16)
b=int(sys.argv[2],16)
sys.exit(0 if a>b else 1)
PY
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

fund_wallet_if_needed() {
  local ns="$1"
  local bal
  bal="$(mcli "$ns" getbalance 2>/dev/null || echo 0)"
  if awk "BEGIN{exit !($bal < 1.0)}"; then
    echo ">> [$ns] low balance ($bal) -> mining 130 to mature coinbase"
    mine_n "$ns" 130
  fi
}

# This isn't a guaranteed doublespend; it's a "conflict pressure" burst.
conflict_pressure_burst() {
  local ns="$1"
  local n="${1:-mgb1}"
  local tries="${CONFLICT_SENDS:-10}"
  echo ">> [$ns] conflict pressure burst: $tries rapid sends (expect ok; goal is mempool pressure, not guaranteed rejects)"
  local a tx
  a="$(mcli "$ns" getnewaddress)"
  tx="$(mcli "$ns" sendtoaddress "$a" 0.01)"
  echo "   first txid=$(short "$tx")"
  for ((i=1;i<=tries;i++)); do
    a="$(mcli "$ns" getnewaddress)"
    mcli "$ns" sendtoaddress "$a" 0.01 >/dev/null 2>&1 || true
  done
}

# ---- Knobs ----
WAIT_SECS="${WAIT_SECS:-120}"
REORG_LIMIT="${REORG_LIMIT:-6}"

# Ensure cw differs BEFORE heal:
# mine more on network side than isolated side
NET_MINE="${NET_MINE:-$((REORG_LIMIT+1))}"
ISO_MINE="${ISO_MINE:-$((REORG_LIMIT))}"

echo "14 reorg-limit exact + heal(no-mine) under real partition [NETNS + ASAN daemons]"
line
echo "Pre-state:"
snapshot mgb1; snapshot mgb2; snapshot mgb3; snapshot mgb4
line

echo ">> Ensure wallets loaded"
ensure_wallet_loaded mgb1
ensure_wallet_loaded mgb2
ensure_wallet_loaded mgb3
ensure_wallet_loaded mgb4
line

echo ">> Apply badnet: insane on mgb1/3/4 + PARTITION on mgb2"
"$BADNET" clear all >/dev/null 2>&1 || true
"$BADNET" insane mgb1
"$BADNET" insane mgb3
"$BADNET" insane mgb4
"$BADNET" partition mgb2
"$BADNET" status || true
line

echo "Phase A: ensure mgb1 has mature funds"
fund_wallet_if_needed mgb1
line

echo "Phase B: mempool pressure/conflict-ish burst while mgb2 partitioned"
conflict_pressure_burst mgb1
line
echo "After Phase B:"
snapshot mgb1; snapshot mgb2; snapshot mgb3; snapshot mgb4
line

echo "Phase C: Mine forks with reorg depth target <= ${REORG_LIMIT}"
echo ">> network side mine on mgb1: NET_MINE=$NET_MINE"
mine_n mgb1 "$NET_MINE"
echo ">> isolated side mine on mgb2: ISO_MINE=$ISO_MINE (should NOT reach others due to partition)"
mine_n mgb2 "$ISO_MINE"

line
echo "During isolation:"
snapshot mgb1; snapshot mgb2; snapshot mgb3; snapshot mgb4
line

echo "Phase D: Heal mgb2 WITHOUT mining, only if CW differs"
cw1="$(chainwork_of mgb1)"
cw2="$(chainwork_of mgb2)"
echo ">> chainwork pre-heal: mgb1..${cw1: -6} mgb2..${cw2: -6}"

if [[ "$cw1" == "$cw2" ]]; then
  echo "❌ TIE chainwork even after partition+mining. This implies either (a) partition not effective, or (b) both mined same net-work."
  echo "   Tip mgb1=$(short "$(mcli mgb1 getbestblockhash)") mgb2=$(short "$(mcli mgb2 getbestblockhash)")"
  echo "   Try increasing NET_MINE or verify partition is on mgb2 veth2."
  exit 2
fi

echo ">> Heal mgb2 + force dial"
"$BADNET" heal mgb2
sleep 1
connect_mgb2_onetry

echo "After heal (waiting up to ${WAIT_SECS}s):"
snapshot mgb1; snapshot mgb2; snapshot mgb3; snapshot mgb4

if ! wait_converge "$WAIT_SECS"; then
  echo "❌ Not converged without mining. Investigate headers announcements under badnet."
  exit 1
fi

line
echo "Post:"
snapshot mgb1; snapshot mgb2; snapshot mgb3; snapshot mgb4
line

echo ">> Cleanup badnet (optional)"
"$BADNET" clear all >/dev/null 2>&1 || true

echo "PASS: reorg<=${REORG_LIMIT} + heal(no-mine) achieved (no post-heal mining)."
line
