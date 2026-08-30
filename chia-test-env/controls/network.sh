#!/usr/bin/env bash

source /workspace/controls/logging.sh

_network_error() {
  test_log ERROR network "$*"
}

_network_interface() {
  local interface
  interface="$(ip -o route show default 2>/dev/null | awk 'NR == 1 {print $5}')"
  if [[ -z "${interface}" ]]; then
    interface="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')"
  fi
  printf '%s\n' "${interface}"
}

_network_resolve() {
  local host="${1:?host missing}"
  getent ahostsv4 "${host}" | awk 'NR == 1 {print $1}'
}

_network_ensure_chains() {
  iptables -N SIA_TEST_OUT 2>/dev/null || true
  iptables -N SIA_TEST_IN 2>/dev/null || true
  iptables -C OUTPUT -j SIA_TEST_OUT 2>/dev/null || iptables -I OUTPUT 1 -j SIA_TEST_OUT
  iptables -C INPUT -j SIA_TEST_IN 2>/dev/null || iptables -I INPUT 1 -j SIA_TEST_IN
}

_network_set_qdisc() {
  local interface
  interface="$(_network_interface)"
  if [[ -z "${interface}" ]]; then
    _network_error 'no non-loopback interface was found'
    return 1
  fi
  tc qdisc replace dev "${interface}" root "$@"
}

network_delay() {
  _network_set_qdisc netem delay "${1:?delay missing}"
}

network_latency() {
  local delay="${1:?delay missing}"
  local jitter="${2:?jitter missing}"
  local correlation="${3:-0%}"
  _network_set_qdisc netem delay "${delay}" "${jitter}" "${correlation}"
}

network_loss() {
  _network_set_qdisc netem loss "${1:?loss percentage missing}"
}

network_duplicate() {
  _network_set_qdisc netem duplicate "${1:?duplication percentage missing}"
}

network_reorder() {
  local percentage="${1:?reorder percentage missing}"
  local correlation="${2:-0%}"
  _network_set_qdisc netem delay 20ms reorder "${percentage}" "${correlation}"
}

network_corrupt() {
  _network_set_qdisc netem corrupt "${1:?corruption percentage missing}"
}

network_rate_limit() {
  _network_set_qdisc tbf rate "${1:?rate missing}" burst 32kbit latency 400ms
}

network_partition_peer() {
  local address
  address="$(_network_resolve "${1:?peer host missing}")"
  _network_ensure_chains
  iptables -C SIA_TEST_OUT -d "${address}" -j DROP 2>/dev/null \
    || iptables -A SIA_TEST_OUT -d "${address}" -j DROP
  iptables -C SIA_TEST_IN -s "${address}" -j DROP 2>/dev/null \
    || iptables -A SIA_TEST_IN -s "${address}" -j DROP
}

network_heal_peer() {
  local address
  address="$(_network_resolve "${1:?peer host missing}")"
  _network_ensure_chains
  while iptables -D SIA_TEST_OUT -d "${address}" -j DROP 2>/dev/null; do :; done
  while iptables -D SIA_TEST_IN -s "${address}" -j DROP 2>/dev/null; do :; done
}

network_partition_port() {
  local host="${1:?peer host missing}"
  local port="${2:?port missing}"
  local address
  address="$(_network_resolve "${host}")"
  _network_ensure_chains
  iptables -C SIA_TEST_OUT -p tcp -d "${address}" --dport "${port}" -j DROP 2>/dev/null \
    || iptables -A SIA_TEST_OUT -p tcp -d "${address}" --dport "${port}" -j DROP
  iptables -C SIA_TEST_OUT -p tcp -d "${address}" --sport "${port}" -j DROP 2>/dev/null \
    || iptables -A SIA_TEST_OUT -p tcp -d "${address}" --sport "${port}" -j DROP
  iptables -C SIA_TEST_IN -p tcp -s "${address}" --dport "${port}" -j DROP 2>/dev/null \
    || iptables -A SIA_TEST_IN -p tcp -s "${address}" --dport "${port}" -j DROP
  iptables -C SIA_TEST_IN -p tcp -s "${address}" --sport "${port}" -j DROP 2>/dev/null \
    || iptables -A SIA_TEST_IN -p tcp -s "${address}" --sport "${port}" -j DROP
}

network_heal_port() {
  local host="${1:?peer host missing}"
  local port="${2:?port missing}"
  local address
  address="$(_network_resolve "${host}")"
  _network_ensure_chains
  while iptables -D SIA_TEST_OUT -p tcp -d "${address}" --dport "${port}" -j DROP 2>/dev/null; do :; done
  while iptables -D SIA_TEST_OUT -p tcp -d "${address}" --sport "${port}" -j DROP 2>/dev/null; do :; done
  while iptables -D SIA_TEST_IN -p tcp -s "${address}" --dport "${port}" -j DROP 2>/dev/null; do :; done
  while iptables -D SIA_TEST_IN -p tcp -s "${address}" --sport "${port}" -j DROP 2>/dev/null; do :; done
}

network_reset() {
  local interface
  interface="$(_network_interface)"
  [[ -z "${interface}" ]] || tc qdisc del dev "${interface}" root >/dev/null 2>&1 || true
  iptables -F SIA_TEST_OUT >/dev/null 2>&1 || true
  iptables -F SIA_TEST_IN >/dev/null 2>&1 || true
  iptables -D OUTPUT -j SIA_TEST_OUT >/dev/null 2>&1 || true
  iptables -D INPUT -j SIA_TEST_IN >/dev/null 2>&1 || true
  iptables -X SIA_TEST_OUT >/dev/null 2>&1 || true
  iptables -X SIA_TEST_IN >/dev/null 2>&1 || true
}

network_show() {
  local interface
  interface="$(_network_interface)"
  [[ -z "${interface}" ]] || tc qdisc show dev "${interface}" || true
  iptables -S SIA_TEST_OUT 2>/dev/null || true
  iptables -S SIA_TEST_IN 2>/dev/null || true
}
