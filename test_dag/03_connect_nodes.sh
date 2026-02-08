#!/usr/bin/env bash
set -euo pipefail

CLI="../megabytes-cli"
AUTH=(-regtest -rpcuser=megabytesrpc -rpcpassword=pass)

rpcport(){ echo $((8331 + $1)); }
datadir(){ echo "/tmp/mgb-node$1"; }

run(){
  local n=$1; shift
  sudo ip netns exec "mgb$n" "$CLI" "${AUTH[@]}" -datadir="$(datadir "$n")" -rpcport="$(rpcport "$n")" "$@"
}

# helper: reset all added nodes (only affects "add", not "onetry")
reset_added(){
  local n=$1
  # getaddednodeinfo true returns a JSON array; this grep/cut works fine for our lab scripts
  mapfile -t peers < <(run "$n" getaddednodeinfo true 2>/dev/null | grep -oE '"addednode":\s*"[^"]+"' | cut -d'"' -f4 || true)
  for p in "${peers[@]}"; do
    run "$n" addnode "$p" remove >/dev/null 2>&1 || true
  done
}

# helper: do onetry but don't fail if it's already connected / transient errors
try_onetry(){
  local n=$1
  local addr=$2
  run "$n" addnode "$addr" onetry >/dev/null 2>&1 || true
}

echo "== Clearing old addnode(add) entries =="
for n in 1 2 3 4; do reset_added "$n"; done

echo "== Doing onetry mesh connects =="
# mgb1 -> 2,3,4
try_onetry 1 10.10.0.12:20000
try_onetry 1 10.10.0.13:30000
try_onetry 1 10.10.0.14:40000

# mgb2 -> 1,3,4
try_onetry 2 10.10.0.11:10000
try_onetry 2 10.10.0.13:30000
try_onetry 2 10.10.0.14:40000

# mgb3 -> 1,2,4
try_onetry 3 10.10.0.11:10000
try_onetry 3 10.10.0.12:20000
try_onetry 3 10.10.0.14:40000

# mgb4 -> 1,2,3
try_onetry 4 10.10.0.11:10000
try_onetry 4 10.10.0.12:20000
try_onetry 4 10.10.0.13:30000

echo "== Peer summary (connectioncount + outbound addrs) =="
for i in 1 2 3 4; do
  echo "--- mgb$i ---"
  run "$i" getconnectioncount || true
  # show a compact view of peer addrs + inbound flag
  run "$i" getpeerinfo | grep -E '"addr":|"inbound":' | head -n 30 || true
done

echo "OK: onetry connections attempted (mesh-style)"