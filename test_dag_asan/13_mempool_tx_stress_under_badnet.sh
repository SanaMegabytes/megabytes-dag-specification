#!/usr/bin/env bash
set -euo pipefail

CLI="/home/**/megabytes/build/src/megabytes-cli"          # normal CLI
DAEMON="/home/**/megabytes/build-asan/src/megabytesd"     # ASAN daemon
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
IP_MGB2="10.10.0.12"
P2P_MGB1="10000"
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

# Keep reorg <= 6
NET_MINE="${NET_MINE:-4}"      # blocks on network side after tx burst
ISO_MINE="${ISO_MINE:-2}"      # blocks on isolated mgb2
POST_HEAL_MINE="${POST_HEAL_MINE:-1}"  # trigger
WAIT_SECS="${WAIT_SECS:-90}"
RESTART_WAIT="${RESTART_WAIT:-20}"

# Stress knobs
TX_BURST="${TX_BURST:-80}"     # number of tx generated (via wallet spend loops)
TX_SPLIT="${TX_SPLIT:-20}"     # fan-out UTXOs first (creates inputs for burst)
FEE_RATE="${FEE_RATE:-1}"      # sat/vB-like (if supported), else ignored by walletfunded ops

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

wait_rpc() {
  local ns="$1" max="$2"
  for ((i=1;i<=max;i++)); do
    if mcli "$ns" getblockcount >/dev/null 2>&1; then
      echo "✅ RPC back after ${i}s ($ns)"
      return 0
    fi
    sleep 1
  done
  echo "⚠️ RPC not responding after ${max}s ($ns)"
  return 1
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

restart_mgb2() {
  echo ">> Restart mgb2 (stress during partition)"
  mcli mgb2 stop >/dev/null 2>&1 || true
  sleep 1
  sudo ip netns exec mgb2 bash -lc "pkill -f 'megabytesd.*-datadir=${DD[mgb2]}'" 2>/dev/null || true
  sleep 1

  sudo ip netns exec mgb2 "$DAEMON" \
    -regtest -daemon \
    -datadir="${DD[mgb2]}" \
    -bind="$IP_MGB2" \
    -port="$P2P_MGB2" \
    -rpcuser="$RPCUSER" \
    -rpcpassword="$RPCPASS" \
    -rpcallowip=127.0.0.1 \
    -rpcport="${RP[mgb2]}" \
    -debug=net -debug=mgbdag

  wait_rpc mgb2 "$RESTART_WAIT"
  ensure_wallet_loaded mgb2
}

connect_mgb2_onetry() {
  mcli mgb2 addnode "${IP_MGB1}:${P2P_MGB1}" onetry >/dev/null 2>&1 || true
}

# ---- TX generator (wallet-driven, no raw tx complexity) ----
# Strategy:
# 1) Ensure mgb1 wallet has spendable coins.
# 2) Fan-out TX_SPLIT small UTXOs to self (creates many inputs).
# 3) Burst TX_BURST sends to new addresses (still mostly to self) to fill mempool.
fund_wallet_if_needed() {
  local ns="$1"
  local bal
  bal="$(mcli "$ns" getbalance 2>/dev/null || echo 0)"
  # If balance is tiny, mine 120 blocks to mature (your chain uses 120 conf)
  # But we try to be minimal: mine 130 once if needed.
  if awk "BEGIN{exit !($bal < 1.0)}"; then
    echo ">> [$ns] low balance ($bal) -> mining 130 to mature coinbase"
    mine_n "$ns" 130
  fi
}

fanout_utxos_self() {
  local ns="$1"
  echo ">> [$ns] fan-out $TX_SPLIT UTXOs to self"
  for ((i=1;i<=TX_SPLIT;i++)); do
    local a
    a="$(mcli "$ns" getnewaddress)"
    # send small amount to fresh address (stays in same wallet)
    mcli "$ns" sendtoaddress "$a" 0.01 >/dev/null
  done
}

burst_txs() {
  local ns="$1"
  echo ">> [$ns] TX burst: $TX_BURST sends"
  for ((i=1;i<=TX_BURST;i++)); do
    local a
    a="$(mcli "$ns" getnewaddress)"
    mcli "$ns" sendtoaddress "$a" 0.001 >/dev/null
  done
}

spotcheck_mempool() {
  local ns="$1"
  echo ">> [$ns] mempoolinfo:"
  mcli "$ns" getmempoolinfo | jq '{size,bytes,usage,maxmempool,mempoolminfee,minrelaytxfee}'
}

echo "13 mempool tx stress under badnet (passable reorg<=6) [NETNS + ASAN daemons]"
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

echo ">> Badnet status (expect insane on 1/3/4 and partition on 2)"
"$BADNET" status || true
line

echo "Phase A: Ensure mgb1 has mature funds + create many tx"
fund_wallet_if_needed mgb1

# Fan-out + burst while mgb2 is partitioned (so it won't see tx yet)
fanout_utxos_self mgb1
burst_txs mgb1

line
echo "After tx generation (still partitioned):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
spotcheck_mempool mgb1
line

echo "Phase B: Mine a few blocks on network side (confirm some tx, but keep reorg small)"
mine_n mgb1 "$NET_MINE"

echo "Phase C: Isolated mgb2 mines small fork (reorg-safe) + restart mgb2"
mine_n mgb2 "$ISO_MINE"
restart_mgb2

line
echo "During isolation (after mining both sides + restart mgb2):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

echo "Phase D: Heal mgb2, force dial, then wait convergence"
"$BADNET" heal mgb2
sleep 1
connect_mgb2_onetry

line
echo "After heal (waiting up to ${WAIT_SECS}s):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4

if ! wait_converge "$WAIT_SECS"; then
  echo "⚠️ Not converged yet — mining ${POST_HEAL_MINE} block(s) to trigger stabilization"
  mine_n mgb1 "$POST_HEAL_MINE"
  sleep 2
  wait_converge "$WAIT_SECS" || echo "⚠️ Still not converged"
fi
line

echo "Post-convergence mempool spotcheck:"
snapshot mgb1
snapshot mgb2
spotcheck_mempool mgb2
line

echo "PASS criteria: no ASAN crash + convergence + mempool behaves (size not exploding / no RPC errors)"
line
