#!/usr/bin/env bash
set -euo pipefail

BIN="../megabytesd"

# mapping namespaces -> datadir/ports
# IPs viennent de 01_net_setup.sh (ex: 10.10.0.11..14)
declare -A NS_IP=(
  [mgb1]="10.10.0.11"
  [mgb2]="10.10.0.12"
  [mgb3]="10.10.0.13"
  [mgb4]="10.10.0.14"
)

declare -A NS_DATADIR=(
  [mgb1]="/tmp/mgb-node1"
  [mgb2]="/tmp/mgb-node2"
  [mgb3]="/tmp/mgb-node3"
  [mgb4]="/tmp/mgb-node4"
)

declare -A NS_P2PPORT=(
  [mgb1]="10000"
  [mgb2]="20000"
  [mgb3]="30000"
  [mgb4]="40000"
)

declare -A NS_RPCPORT=(
  [mgb1]="8332"
  [mgb2]="8333"
  [mgb3]="8334"
  [mgb4]="8335"
)

COMMON_ARGS=(
  -regtest
  -rpcuser=megabytesrpc
  -rpcpassword=pass
  -rpcallowip=127.0.0.1
  -debug=net
  -debug=mgbdag
  -daemon
)

for ns in mgb1 mgb2 mgb3 mgb4; do
  ip="${NS_IP[$ns]}"
  datadir="${NS_DATADIR[$ns]}"
  p2p="${NS_P2PPORT[$ns]}"
  rpc="${NS_RPCPORT[$ns]}"

  sudo ip netns exec "$ns" "$BIN" \
    -datadir="$datadir" \
    -bind="$ip" \
    -port="$p2p" \
    -rpcport="$rpc" \
    "${COMMON_ARGS[@]}"
done

echo "OK: nodes started"