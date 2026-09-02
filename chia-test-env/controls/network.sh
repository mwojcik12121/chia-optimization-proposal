#!/usr/bin/env bash

_network_resolve() {
  local host="${1:?host missing}"
  getent ahostsv4 "${host}" | awk 'NR == 1 {print $1}'
}

_network_ensure_chains() {
  iptables -N CHIA_TEST_OUT 2>/dev/null || true
  iptables -N CHIA_TEST_IN 2>/dev/null || true
  iptables -C OUTPUT -j CHIA_TEST_OUT 2>/dev/null || iptables -I OUTPUT 1 -j CHIA_TEST_OUT
  iptables -C INPUT -j CHIA_TEST_IN 2>/dev/null || iptables -I INPUT 1 -j CHIA_TEST_IN
}

network_partition_port() {
  local host="${1:?peer host missing}"
  local port="${2:?port missing}"
  local address
  address="$(_network_resolve "${host}")"
  _network_ensure_chains
  iptables -C CHIA_TEST_OUT -p tcp -d "${address}" --dport "${port}" -j DROP 2>/dev/null \
    || iptables -A CHIA_TEST_OUT -p tcp -d "${address}" --dport "${port}" -j DROP
  iptables -C CHIA_TEST_OUT -p tcp -d "${address}" --sport "${port}" -j DROP 2>/dev/null \
    || iptables -A CHIA_TEST_OUT -p tcp -d "${address}" --sport "${port}" -j DROP
  iptables -C CHIA_TEST_IN -p tcp -s "${address}" --dport "${port}" -j DROP 2>/dev/null \
    || iptables -A CHIA_TEST_IN -p tcp -s "${address}" --dport "${port}" -j DROP
  iptables -C CHIA_TEST_IN -p tcp -s "${address}" --sport "${port}" -j DROP 2>/dev/null \
    || iptables -A CHIA_TEST_IN -p tcp -s "${address}" --sport "${port}" -j DROP
}

network_heal_port() {
  local host="${1:?peer host missing}"
  local port="${2:?port missing}"
  local address
  address="$(_network_resolve "${host}")"
  _network_ensure_chains
  while iptables -D CHIA_TEST_OUT -p tcp -d "${address}" --dport "${port}" -j DROP 2>/dev/null; do :; done
  while iptables -D CHIA_TEST_OUT -p tcp -d "${address}" --sport "${port}" -j DROP 2>/dev/null; do :; done
  while iptables -D CHIA_TEST_IN -p tcp -s "${address}" --dport "${port}" -j DROP 2>/dev/null; do :; done
  while iptables -D CHIA_TEST_IN -p tcp -s "${address}" --sport "${port}" -j DROP 2>/dev/null; do :; done
}

network_reset() {
  iptables -F CHIA_TEST_OUT >/dev/null 2>&1 || true
  iptables -F CHIA_TEST_IN >/dev/null 2>&1 || true
  iptables -D OUTPUT -j CHIA_TEST_OUT >/dev/null 2>&1 || true
  iptables -D INPUT -j CHIA_TEST_IN >/dev/null 2>&1 || true
  iptables -X CHIA_TEST_OUT >/dev/null 2>&1 || true
  iptables -X CHIA_TEST_IN >/dev/null 2>&1 || true
}
