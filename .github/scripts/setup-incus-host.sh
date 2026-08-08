#!/usr/bin/env bash

set -euo pipefail

__ensure_forward_rule() {
  local _chain="$1"
  shift

  if sudo iptables --wait 5 --check "${_chain}" "$@" 2>/dev/null; then
    return
  fi
  sudo iptables --wait 5 --insert "${_chain}" 1 "$@"
}

__main() {
  local _forward_chain=FORWARD
  local _ipv4_address _ipv4_nat

  sudo systemctl enable --now incus.socket
  sudo incus admin waitready
  sudo incus admin init --minimal

  if sudo iptables --wait 5 --numeric --list DOCKER-USER >/dev/null 2>&1; then
    _forward_chain=DOCKER-USER
  fi
  __ensure_forward_rule "${_forward_chain}" \
    --in-interface incusbr0 \
    --jump ACCEPT
  __ensure_forward_rule "${_forward_chain}" \
    --out-interface incusbr0 \
    --match conntrack \
    --ctstate RELATED,ESTABLISHED \
    --jump ACCEPT

  test "$(sudo sysctl -n net.ipv4.ip_forward)" = 1
  _ipv4_address="$(sudo incus network get incusbr0 ipv4.address)"
  _ipv4_nat="$(sudo incus network get incusbr0 ipv4.nat)"
  test -n "${_ipv4_address}"
  test "${_ipv4_address}" != none
  test "${_ipv4_nat}" = true
  test -c /dev/kvm

  sudo incus version
  sudo incus network show incusbr0
  sudo iptables --wait 5 --numeric --verbose --list "${_forward_chain}"
}

__main "$@"
