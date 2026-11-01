#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"

_action_error() {
  test_log ERROR action "$*"
}

_action_rpc() {
  local service="${1:?service missing}"
  local endpoint="${2:?endpoint missing}"
  local request="${3:-}"
  [[ -n "${request}" ]] || request='{}'
  chia rpc "${service}" "${endpoint}" "${request}"
}

_action_require_role() {
  local expected="${1:?role missing}"
  if [[ "${NODE_ROLE:-}" != "${expected}" ]]; then
    _action_error "role ${expected} is required"
    return 1
  fi
}

_action_blockchain_state() {
  _action_rpc full_node get_blockchain_state '{}' 2>/dev/null
}

_action_peak_height() {
  _action_blockchain_state | jq -r '.blockchain_state.peak.height // -1'
}

_action_peak_hash() {
  _action_blockchain_state | jq -r '.blockchain_state.peak.header_hash // empty'
}

action_start_services() {
  local group="${1:?service group missing}"
  chia start "${group}" >/dev/null 2>&1
}

action_stop_services() {
  local group="${1:?service group missing}"
  chia stop "${group}" >/dev/null 2>&1 || true
}

action_wait_for_full_node_rpc() {
  local timeout="${1:-180}"
  local elapsed=0
  until _action_rpc full_node healthz '{}' >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      _action_error "full-node RPC timeout after ${timeout}s"
      return 1
    fi
  done
}

action_wait_for_height() {
  local target="${1:?target height missing}"
  local timeout="${2:-600}"
  local start now height
  start="$(date +%s)"
  while true; do
    height="$(_action_peak_height 2>/dev/null || printf '%s' -1)"
    if [[ "${height}" =~ ^[0-9]+$ ]] && (( height >= target )); then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      _action_error "height ${target} was not reached"
      return 1
    fi
    sleep 0.1
  done
}

action_wait_for_peak_hash() {
  local expected="${1:?peak hash missing}"
  local timeout="${2:-300}"
  local start now current normalized_expected normalized_current
  normalized_expected="${expected#0x}"
  normalized_expected="${normalized_expected,,}"
  start="$(date +%s)"
  while true; do
    current="$(_action_peak_hash 2>/dev/null || true)"
    normalized_current="${current#0x}"
    normalized_current="${normalized_current,,}"
    [[ -n "${normalized_current}" && "${normalized_current}" == "${normalized_expected}" ]] && return 0
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      _action_error "peak did not converge to ${expected}"
      return 1
    fi
    sleep 0.2
  done
}


_action_wait_for_named_processes() {
  local timeout="${1:-60}"
  shift
  local start=$SECONDS name running
  while (( SECONDS - start < timeout )); do
    running=0
    for name in "$@"; do
      if pgrep -x "${name}" >/dev/null 2>&1; then
        running=1
        break
      fi
    done
    (( running == 0 )) && return 0
    sleep 0.1
  done
  _action_error "processes did not stop: $*"
  return 1
}

_action_wait_for_vdf_exit() {
  local timeout="${1:-60}"
  local start=$SECONDS
  while (( SECONDS - start < timeout )); do
    pgrep -f '(^|/)vdf_client([^/ ]*)?( |$)' >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  _action_error 'VDF clients did not stop'
  return 1
}

action_start_farming() {
  _action_require_role farmer
  action_start_services farmer-only
  action_start_services harvester
}

action_stop_farming() {
  _action_require_role farmer
  action_stop_services farmer-only
  action_stop_services harvester
  _action_wait_for_named_processes 60 chia_farmer chia_harvester
}

action_wait_for_plot() {
  local timeout="${1:-180}"
  local elapsed=0 response count
  while true; do
    response="$(_action_rpc harvester get_plots '{}' 2>/dev/null || true)"
    count="$(jq -r '(.plots // []) | length' <<<"${response}" 2>/dev/null || printf '%s' 0)"
    [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )) && return 0
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      _action_error "no plot loaded after ${timeout}s"
      return 1
    fi
  done
}

action_start_timelord_server() {
  _action_require_role timelord
  action_start_services timelord-only
}

action_wait_for_vdf_server() {
  local timeout="${1:-180}"
  local elapsed=0
  _action_require_role timelord
  until ss -Hltn 2>/dev/null | awk '$4 ~ /:8000$/ {found=1} END {exit !found}'; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      _action_error "VDF server timeout after ${timeout}s"
      return 1
    fi
  done
}

action_start_timelord_vdf() {
  _action_require_role timelord
  action_start_services timelord-launcher-only
}

action_start_timelord() {
  action_start_timelord_server
  action_start_timelord_vdf
}

action_stop_timelord() {
  _action_require_role timelord
  # Let launcher-owned VDF clients exit before removing their timelord server.
  # This avoids noisy client aborts and makes the stop barrier meaningful.
  action_stop_services timelord-launcher-only
  _action_wait_for_vdf_exit 60
  action_stop_services timelord-only
  _action_wait_for_named_processes 60 chia_timelord
}

action_start_vdf() {
  _action_require_role vdf
  action_start_services timelord-launcher-only
}

action_stop_vdf() {
  _action_require_role vdf
  action_stop_services timelord-launcher-only
  _action_wait_for_vdf_exit 60
}

_action_vdf_client_count() {
  ss -Htn state established 2>/dev/null \
    | awk '$3 ~ /:8000$/ {count++} END {print count + 0}'
}

action_wait_for_vdf_clients() {
  local expected="${1:-3}"
  local timeout="${2:-300}"
  local elapsed=0 count
  _action_require_role timelord
  while true; do
    count="$(_action_vdf_client_count)"
    (( count >= expected )) && return 0
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      _action_error "VDF client timeout: ${count}/${expected}"
      return 1
    fi
  done
}

action_signal_serve() {
  local port="${1:?port missing}"
  local expected="${2:?client count missing}"
  local message="${3:?message missing}"
  local timeout="${4:-900}"
  chia-signal serve "${port}" "${expected}" "${message}" "${timeout}"
}

action_signal_wait() {
  local host="${1:?server host missing}"
  local port="${2:?port missing}"
  local timeout="${3:-900}"
  chia-signal wait "${host}" "${port}" "${NODE_NAME:-node-unknown}" "${timeout}"
}
