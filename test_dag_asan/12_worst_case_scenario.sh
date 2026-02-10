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

if [[ ! -x "$CLI" ]]; then echo "Missing CLI: $CLI"; exit 1; fi
if [[ ! -x "$DAEMON" ]]; then echo "Missing DAEMON: $DAEMON"; exit 1; fi
if [[ ! -x "$BADNET" ]]; then echo "Missing badnet script: $BADNET"; exit 1; fi

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

# Reorg-safe tunables (<=6)
NET_MINE="${NET_MINE:-5}"     # blocks mined by the network side (mgb1)
ISO_MINE="${ISO_MINE:-2}"     # blocks mined by isolated mgb2 (local fork)
WAIT_SECS="${WAIT_SECS:-45}"
RESTART_WAIT="${RESTART_WAIT:-20}"

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

  if mcli "$ns" listwallets 2>/dev/null | jq -e --arg w "$w" '.[] | select(.==$w)' >/dev/null 2>&1; then
    echo "   [$ns] wallet already loaded: $w"
    return 0
  fi
  if mcli "$ns" loadwallet "$w" >/dev/null 2>&1; then
    echo "   [$ns] loadwallet OK: $w"
    return 0
  fi

  mcli "$ns" createwallet "$w" >/dev/null 2>&1 || true
  mcli "$ns" loadwallet "$w" >/dev/null 2>&1 || true
  echo "   [$ns] wallet ready (best-effort): $w"
}

snapshot() {
  local ns="$1"
  local h tip hdr cw
  h="$(mcli "$ns" getblockcount)"
  tip="$(mcli "$ns" getbestblockhash)"
  hdr="$(mcli "$ns" getblockheader "$tip" true)"
  cw="$(echo "$hdr" | jq -r '.chainwork')"
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
    if mcli "$ns" getblockcount >/dev/null 2>&1; then
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
  echo ">> Restart mgb2 while still isolated (stress)"
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
  # Force mgb2 to dial mgb1 after heal
  mcli mgb2 addnode "${IP_MGB1}:${P2P_MGB1}" onetry >/dev/null 2>&1 || true
}

spotcheck_dagmeta_tip() {
  local tip
  tip="$(mcli mgb1 getbestblockhash)"
  echo ">> [mgb2] getdagmeta tip=$(short "$tip")"
  mcli mgb2 getdagmeta "$tip" | jq '{hash,height,has_meta,sp_match,blue_score_match,blue_steps_match,flags:(.meta_db.flags_decoded // null)}'
}

echo "12 worst-case (passable): insane net + mgb2 isolated fork + restart + heal (reorg<=6)"
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

echo ">> ASSERT: you already applied badnet (insane on 1,3,4 and partition mgb2)"
echo ">> (Not changing it here, except we WILL heal mgb2 later.)"
"$BADNET" status || true
line

echo "Phase A: while mgb2 is PARTITIONED, create small fork both sides (reorg-safe)"
echo " - Network side (mgb1) mines +$NET_MINE"
mine_n mgb1 "$NET_MINE"

echo " - Isolated mgb2 mines local +$ISO_MINE (creates fork depth <= $ISO_MINE)"
mine_n mgb2 "$ISO_MINE"

line
echo "During isolation:"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

restart_mgb2_only

line
echo "After mgb2 restart (still isolated):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4
line

echo "Phase B: HEAL mgb2 (still insane elsewhere) and force resync"
"$BADNET" heal mgb2
# "$BADNET" insane mgb2
"$BADNET" status || true

sleep 1
connect_mgb2_onetry

line
echo "After heal (waiting up to ${WAIT_SECS}s for convergence):"
snapshot mgb1
snapshot mgb2
snapshot mgb3
snapshot mgb4

if ! wait_converge "$WAIT_SECS"; then
  echo "⚠️ Passive convergence failed — mining 1 block on mgb1 to trigger stabilization"
  mine_n mgb1 1
  sleep 2
  wait_converge "$WAIT_SECS" || echo "⚠️ Still not converged"
fi
line

spotcheck_dagmeta_tip || true

echo
echo "PASS criteria: no ASAN crash + convergence + getdagmeta OK"
line
