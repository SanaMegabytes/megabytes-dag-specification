#!/usr/bin/env bash
set -euo pipefail

# 08_diag_divergence.sh
# Diagnostic "NOW" for 4 regtest nodes in netns (mgb1..mgb4).
# Focus: why one node isn't converged (headers-only vs blocks, missing block body, peers inflight, DAG meta).
#
# Usage:
#   ./08_diag_divergence.sh
# Env knobs:
#   LAST_N=15                 # how many recent hashes to compare/list
#   DUMP_JSON=0               # 1 => include raw JSON blobs (bigger output)
#   DAG_VALIDATE=1            # 1 => run getdagmeta/getblockdag for a few strategic blocks
#   DAG_VALIDATE_N=3          # how many blocks to validate (tip/mid/oldest from last list)
#   DAG_VALIDATE_NS=mgb1      # node to run DAG RPC validations on
#
# Notes:
# - Handles the common "equal height but different tip" situation.
# - Detects if node has header but not block (getblockheader ok, getblock fails).
# - Prints peers inflight summary (synced_headers/blocks, inflight count, ping).

CLI="../megabytes-cli"
NETWORK="-regtest"
RPCUSER="megabytesrpc"
RPCPASS="pass"

LAST_N="${LAST_N:-15}"
DUMP_JSON="${DUMP_JSON:-0}"

DAG_VALIDATE="${DAG_VALIDATE:-1}"
DAG_VALIDATE_N="${DAG_VALIDATE_N:-3}"
DAG_VALIDATE_NS="${DAG_VALIDATE_NS:-mgb1}"

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
need jq
need sudo
need ip
need timeout

short() { echo "${1:-}" | cut -c1-12; }
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

mcli_timeout() {
  local ns="$1"; shift
  local datadir="${NS_DATADIR[$ns]}"
  local rpcport="${NS_RPCPORT[$ns]}"

  # timeout a besoin d'un vrai binaire (pas une fonction).
  timeout 20s sudo ip netns exec "$ns" "$CLI" \
    "$NETWORK" \
    -datadir="$datadir" \
    -rpcuser="$RPCUSER" \
    -rpcpassword="$RPCPASS" \
    -rpcconnect=127.0.0.1 \
    -rpcport="$rpcport" \
    "$@"
}



safe_json() {
  # prints json if DUMP_JSON=1 else prints short/filtered
  local json="$1"
  if [[ "$DUMP_JSON" == "1" ]]; then
    echo "$json"
  else
    echo "$json" | jq -c .
  fi
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

header_fingerprint() {
  local ns="$1" h="$2"
  mcli "$ns" getblockheader "$h" | jq -r '[
    .height,
    (.hash|.[0:12]),
    (.pow_algo // "?"),
    (.pow_algo_id // "?"),
    (.chainwork|.[0:16]),
    (.previousblockhash|.[0:12])
  ] | @tsv'
}

has_block_body() {
  local ns="$1" h="$2"
  # If getblock (verbosity 1) fails, likely headers-only or pruned/missing.
  if mcli "$ns" getblock "$h" 1 >/dev/null 2>&1; then
    echo "YES"
  else
    echo "NO"
  fi
}

peers_summary() {
  local ns="$1"
  mcli "$ns" getpeerinfo | jq -c '
    map({
      id,
      inbound,
      addr,
      ping:(.pingtime // null),
      sh:(.synced_headers // null),
      sb:(.synced_blocks // null),
      inflight:(.inflight|length),
      conn:(.connection_type // "")
    }) | sort_by(.inbound, .id)'
}

chaintips_quick() {
  local ns="$1"
  mcli "$ns" getchaintips | jq -c '.[0:8] | map({height, hash:(.hash|.[0:12]), branchlen, status})'
}

# DAG validations (strategic)
dag_validate_block() {
  local ns="$1" hash="$2"
  local out

  echo ">> [$ns] getblock $hash 2"
  out="$(mcli_timeout "$ns" getblock "$hash" 2 2>&1)" || {
    echo "   ERROR(getblock):"
    echo "$out" | sed -n '1,12p'
    out=""
  }
  if [[ -n "$out" ]]; then
    echo "$out" | jq -c '{
      hash, confirmations, height, time,
      previousblockhash,
      merkleroot,
      ntx:(.tx|length)
    }' 2>/dev/null || {
      echo "   (non-JSON output)"
      echo "$out" | sed -n '1,12p'
    }
  fi

  echo ">> [$ns] getdagmeta $hash"
  out="$(mcli_timeout "$ns" getdagmeta "$hash" 2>&1)" || {
    echo "   ERROR(getdagmeta):"
    echo "$out" | sed -n '1,12p'
    out=""
  }
  [[ -n "$out" ]] && echo "$out" | sed -n '1,80p'

  echo ">> [$ns] getblockdag $hash"
  out="$(mcli_timeout "$ns" getblockdag "$hash" 2>&1)" || {
    echo "   ERROR(getblockdag):"
    echo "$out" | sed -n '1,12p'
    out=""
  }
  [[ -n "$out" ]] && echo "$out" | sed -n '1,80p'
}

pick_indices() {
  local len="$1"
  local -a idx=()
  idx+=(0)
  if (( len > 2 )); then idx+=($((len/2))); fi
  if (( len > 1 )); then idx+=($((len-1))); fi
  printf "%s\n" "${idx[@]}"
}

shortcw() { local s="$1"; echo "${s:0:12}..${s: -6}"; }

echo "08 diag NOW: divergence / convergence / headers-only / peers / DAG"
line
echo "== Node summaries (blocks/headers/tip/cw) =="

declare -A TIP=() HEIGHT=() HEADERS=() CW=() IBD=()
for ns in mgb1 mgb2 mgb3 mgb4; do
  bci="$(mcli "$ns" getblockchaininfo)"
  TIP["$ns"]="$(echo "$bci" | jq -r '.bestblockhash')"
  HEIGHT["$ns"]="$(echo "$bci" | jq -r '.blocks')"
  HEADERS["$ns"]="$(echo "$bci" | jq -r '.headers')"
  CW["$ns"]="$(echo "$bci" | jq -r '.chainwork')"
  IBD["$ns"]="$(echo "$bci" | jq -r '.initialblockdownload')"
  printf "%-4s  h=%-5s  headers=%-5s  ibd=%-5s  tip=%s  cw=%s\n" \
    "$ns" "${HEIGHT[$ns]}" "${HEADERS[$ns]}" "${IBD[$ns]}" "$(short "${TIP[$ns]}")" "$(shortcw "${CW[$ns]}")"
done

line
echo "== Convergence check (same tip?) =="
base="${TIP[mgb1]}"
same="YES"
for ns in mgb2 mgb3 mgb4; do
  [[ "${TIP[$ns]}" == "$base" ]] || same="NO"
done
if [[ "$same" == "YES" ]]; then
  echo "OK: all 4 nodes on same tip: $(short "$base") (h=${HEIGHT[mgb1]})"
else
  echo "WARN: tips differ:"
  for ns in mgb1 mgb2 mgb3 mgb4; do
    echo "  $ns tip=$(short "${TIP[$ns]}") h=${HEIGHT[$ns]} headers=${HEADERS[$ns]} cw=$(shortcw "${CW[$ns]}")"
  done
fi

line
echo "== Compare last $LAST_N hashes (tip->backward) =="
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for ns in mgb1 mgb2 mgb3 mgb4; do
  get_last_hashes "$ns" "$LAST_N" > "$tmpdir/$ns.last"
done

same_hist="YES"
for ns in mgb2 mgb3 mgb4; do
  if ! diff -q "$tmpdir/mgb1.last" "$tmpdir/$ns.last" >/dev/null; then
    same_hist="NO"
  fi
done

if [[ "$same_hist" == "YES" ]]; then
  echo "OK: last $LAST_N blocks identical on all nodes."
else
  echo "DIFF: last $LAST_N differs."
  for ns in mgb2 mgb3 mgb4; do
    if ! diff -q "$tmpdir/mgb1.last" "$tmpdir/$ns.last" >/dev/null; then
      echo "---- first mismatch (mgb1 vs $ns) ----"
      diff -u "$tmpdir/mgb1.last" "$tmpdir/$ns.last" | sed -n '1,80p'
    fi
  done
fi

line
echo "== Tip fingerprints + 'has block body?' (headers-only detector) =="
for ns in mgb1 mgb2 mgb3 mgb4; do
  tip="${TIP[$ns]}"
  fp="$(header_fingerprint "$ns" "$tip" 2>/dev/null || true)"
  body="$(has_block_body "$ns" "$tip")"
  if [[ -n "$fp" ]]; then
    echo "$ns  tip=$(short "$tip")  has_block=$body  $(echo "$fp" | awk -F'\t' '{printf("height=%s algo=%s cw=%s prev=%s\n",$1,$3,$5,$6)}')"
  else
    echo "$ns  tip=$(short "$tip")  header=MISSING (weird)"
  fi
done

line
echo "== If diverged: check whether each node has the OTHER tips (header vs body) =="
# Collect unique tips
tips_uniq="$(printf "%s\n" "${TIP[mgb1]}" "${TIP[mgb2]}" "${TIP[mgb3]}" "${TIP[mgb4]}" | awk 'NF' | sort -u)"
mapfile -t TIPSU < <(echo "$tips_uniq")

if (( ${#TIPSU[@]} <= 1 )); then
  echo "All tips identical; skip cross-tip checks."
else
  echo "Unique tips:"
  for h in "${TIPSU[@]}"; do echo "  - $(short "$h")"; done
  echo
  for ns in mgb1 mgb2 mgb3 mgb4; do
    echo "-- $ns --"
    for h in "${TIPSU[@]}"; do
      # header exists?
      if mcli "$ns" getblockheader "$h" >/dev/null 2>&1; then
        hb="H"
      else
        hb="-"
      fi
      bb="$(has_block_body "$ns" "$h")"
      printf "  tip=%s  header=%s  body=%s\n" "$(short "$h")" "$hb" "$bb"
    done
  done
fi

line
echo "== Quick chaintips (top 8) =="
for ns in mgb1 mgb2 mgb3 mgb4; do
  echo "[$ns] $(chaintips_quick "$ns")"
done

line
echo "== Peers summary (inflight / synced_headers/blocks) =="
for ns in mgb1 mgb2 mgb3 mgb4; do
  echo "-- $ns --"
  peers_summary "$ns" | jq -r '
    .[] | [
      ("id=" + (.id|tostring)),
      (if .inbound then "in" else "out" end),
      ("sh=" + ((.sh//-1)|tostring)),
      ("sb=" + ((.sb//-1)|tostring)),
      ("inflight=" + ((.inflight//0)|tostring)),
      ("ping=" + (if .ping==null then "null" else (.ping|tostring) end)),
      ("addr=" + .addr)
    ] | join(" ")'
done

line
echo "== Strategic spot-check from mgb1 last list (header + body availability across nodes) =="
mapfile -t LST < "$tmpdir/mgb1.last"
len="${#LST[@]}"
if (( len == 0 )); then
  echo "No blocks in list."
  exit 2
fi

mapfile -t IDX < <(pick_indices "$len")
for i in "${IDX[@]}"; do
  h="${LST[$i]}"
  echo "Block $(short "$h") (idx=$i):"
  for ns in mgb1 mgb2 mgb3 mgb4; do
    if mcli "$ns" getblockheader "$h" >/dev/null 2>&1; then
      body="$(has_block_body "$ns" "$h")"
      fp="$(header_fingerprint "$ns" "$h" 2>/dev/null || true)"
      if [[ -n "$fp" ]]; then
        echo "  $ns  has_block=$body  $(echo "$fp" | awk -F'\t' '{printf("height=%s algo=%s cw=%s prev=%s\n",$1,$3,$5,$6)}')"
      else
        echo "  $ns  header=OK has_block=$body"
      fi
    else
      echo "  $ns  header=MISSING"
    fi
  done
done

if [[ "$DAG_VALIDATE" == "1" ]]; then
  line
  echo "== DAG / pool-operator validations (on $DAG_VALIDATE_NS only) =="
  echo "Pool operators can validate mined blocks using:"
  echo "  megabytes-cli getblock <blockhash> 2"
  echo "  megabytes-cli getdagmeta <blockhash>"
  echo "  megabytes-cli getblockdag <blockhash>"
  echo

  # pick same indices (tip/mid/oldest) then trim to DAG_VALIDATE_N
  VH=()
  for i in "${IDX[@]}"; do
    VH+=("${LST[$i]}")
  done

  # dedup
  declare -A seen=()
  VH2=()
  for h in "${VH[@]}"; do
    [[ -n "$h" ]] || continue
    if [[ -z "${seen[$h]+x}" ]]; then
      seen["$h"]=1
      VH2+=("$h")
    fi
  done
  VH=("${VH2[@]:0:$DAG_VALIDATE_N}")

  echo "Validating ${#VH[@]} block(s):"
  for h in "${VH[@]}"; do echo "  - $(short "$h")"; done
  echo

  n=0
  for h in "${VH[@]}"; do
    n=$((n+1))
    echo "---- DAG validate #$n / ${#VH[@]} ----"
    dag_validate_block "$DAG_VALIDATE_NS" "$h"
    echo
  done
fi

line
if [[ "$same" == "YES" && "$same_hist" == "YES" ]]; then
  echo "RESULT: ✅ PASS (synced; history matches)."
  echo "Note: forks in chaintips are normal after races; only active tip/history must match."
else
  echo "RESULT: ⚠️  NOT FULLY CONVERGED."
  echo "Interpretation tips:"
  echo " - If some node shows header=H but body=NO for the winning tip: it's still downloading block bodies (normal for a moment)."
  echo " - If headers==blocks on all nodes but tips differ: likely tie/fork unresolved (needs deterministic tie-break or 1 more block to break)."
  echo " - Use the peers summary to see who is behind (sb/sh, inflight)."
fi