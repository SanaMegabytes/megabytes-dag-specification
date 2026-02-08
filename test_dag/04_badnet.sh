#!/usr/bin/env bash
# File: 04_badnet.sh
# Usage:
#   ./04_badnet.sh status
#   ./04_badnet.sh clear [mgb1|mgb2|mgb3|mgb4|all]
#   ./04_badnet.sh medium [mgbX|all]
#   ./04_badnet.sh hard [mgbX|all]
#   ./04_badnet.sh insane [mgbX|all]
#   ./04_badnet.sh partition mgbX
#   ./04_badnet.sh heal mgbX
#
# Notes:
# - Requires 01_net_setup.sh already ran (namespaces exist).
# - Interfaces assumed: mgb1->veth1, mgb2->veth2, mgb3->veth3, mgb4->veth4

set -euo pipefail

NS_LIST=(mgb1 mgb2 mgb3 mgb4)

iface_for_ns() {
  case "$1" in
    mgb1) echo "veth1" ;;
    mgb2) echo "veth2" ;;
    mgb3) echo "veth3" ;;
    mgb4) echo "veth4" ;;
    *) echo "unknown" ;;
  esac
}

apply_clear() {
  local ns="$1"
  local dev
  dev="$(iface_for_ns "$ns")"
  if [[ "$dev" == "unknown" ]]; then
    echo "Unknown ns: $ns" >&2
    exit 1
  fi
  sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
  echo "[$ns] cleared"
}

apply_profile_medium() {
  local ns="$1"
  local dev
  dev="$(iface_for_ns "$ns")"

  # delay/jitter + small loss + small reorder
  sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
  sudo ip netns exec "$ns" tc qdisc add dev "$dev" root netem \
    delay 120ms 60ms distribution normal \
    loss 1% \
    reorder 2% 50%
  echo "[$ns] applied: medium"
}

apply_profile_hard() {
  local ns="$1"
  local dev
  dev="$(iface_for_ns "$ns")"

  sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true

  # rate-limit + netem stacked
  sudo ip netns exec "$ns" tc qdisc add dev "$dev" root handle 1: tbf \
    rate 2mbit burst 64kbit latency 600ms
  sudo ip netns exec "$ns" tc qdisc add dev "$dev" parent 1:1 handle 10: netem \
    delay 250ms 120ms distribution normal \
    loss 4% \
    duplicate 0.5% \
    reorder 8% 50%
  echo "[$ns] applied: hard"
}

apply_profile_insane() {
  local ns="$1"
  local dev
  dev="$(iface_for_ns "$ns")"

  sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true

  # very low bandwidth + heavy netem
  sudo ip netns exec "$ns" tc qdisc add dev "$dev" root handle 1: tbf \
    rate 768kbit burst 32kbit latency 1200ms
  sudo ip netns exec "$ns" tc qdisc add dev "$dev" parent 1:1 handle 10: netem \
    delay 450ms 250ms distribution normal \
    loss 10% \
    duplicate 2% \
    reorder 20% 50% \
    corrupt 0.2%
  echo "[$ns] applied: insane"
}

apply_partition() {
  local ns="$1"
  local dev
  dev="$(iface_for_ns "$ns")"

  sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
  sudo ip netns exec "$ns" tc qdisc add dev "$dev" root netem loss 100%
  echo "[$ns] applied: PARTITION (loss 100%)"
}

show_status() {
  for ns in "${NS_LIST[@]}"; do
    local dev
    dev="$(iface_for_ns "$ns")"
    echo "==== $ns ($dev) ===="
    sudo ip netns exec "$ns" tc qdisc show dev "$dev" || true
  done
}

target_expand() {
  local tgt="${1:-all}"
  if [[ "$tgt" == "all" ]]; then
    printf "%s\n" "${NS_LIST[@]}"
  else
    printf "%s\n" "$tgt"
  fi
}

cmd="${1:-}"
tgt="${2:-all}"

case "$cmd" in
  status)
    show_status
    ;;
  clear)
    for ns in $(target_expand "$tgt"); do
      apply_clear "$ns"
    done
    ;;
  medium)
    for ns in $(target_expand "$tgt"); do
      apply_profile_medium "$ns"
    done
    ;;
  hard)
    for ns in $(target_expand "$tgt"); do
      apply_profile_hard "$ns"
    done
    ;;
  insane)
    for ns in $(target_expand "$tgt"); do
      apply_profile_insane "$ns"
    done
    ;;
  partition)
    if [[ -z "${2:-}" || "${2:-}" == "all" ]]; then
      echo "Usage: ./04_badnet.sh partition mgbX" >&2
      exit 1
    fi
    apply_partition "$2"
    ;;
  heal)
    if [[ -z "${2:-}" || "${2:-}" == "all" ]]; then
      echo "Usage: ./04_badnet.sh heal mgbX" >&2
      exit 1
    fi
    apply_clear "$2"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    echo "Try: status | clear [mgbX|all] | medium|hard|insane [mgbX|all] | partition mgbX | heal mgbX" >&2
    exit 1
    ;;
esac