#!/usr/bin/env bash
set -euo pipefail

BR=mgbbr0
NS=(mgb1 mgb2 mgb3 mgb4)
IPS=(10.10.0.11 10.10.0.12 10.10.0.13 10.10.0.14)

cleanup() {
  set +e
  for n in "${NS[@]}"; do
    sudo ip netns del "$n" 2>/dev/null
  done
  sudo ip link del "$BR" 2>/dev/null
}

# cleanup

# Bridge
sudo ip link add name "$BR" type bridge
sudo ip link set "$BR" up

for i in "${!NS[@]}"; do
  n="${NS[$i]}"
  ipaddr="${IPS[$i]}"
  veth_host="vethh$((i+1))"
  veth_ns="veth$((i+1))"

  sudo ip netns add "$n"

  #  veth
  sudo ip link add "$veth_host" type veth peer name "$veth_ns"
  sudo ip link set "$veth_ns" netns "$n"

  #  bridge
  sudo ip link set "$veth_host" master "$BR"
  sudo ip link set "$veth_host" up

  #  namespace
  sudo ip netns exec "$n" ip link set lo up
  sudo ip netns exec "$n" ip link set "$veth_ns" up
  sudo ip netns exec "$n" ip addr add "$ipaddr/24" dev "$veth_ns"

  # route 
  sudo ip netns exec "$n" ip route add default via 10.10.0.1 2>/dev/null || true
done

# IP “gateway” 
sudo ip addr add 10.10.0.1/24 dev "$BR" 2>/dev/null || true

echo "OK: namespaces up"
sudo ip netns list
