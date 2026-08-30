#!/usr/bin/env bash

source /workspace/controls/logging.sh

_action_error() {
  test_log ERROR action "$*"
}

_action_rpc() {
  local service="${1:?service missing}"
  local endpoint="${2:?endpoint missing}"
  local request="${3:-{}}"
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

action_restart_services() {
  local group="${1:?service group missing}"
  chia start -r "${group}" >/dev/null 2>&1
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

action_wait_for_wallet_rpc() {
  local timeout="${1:-240}"
  local elapsed=0
  until _action_rpc wallet get_sync_status '{}' >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      _action_error "wallet RPC timeout after ${timeout}s"
      return 1
    fi
  done
}

action_wait_for_wallet_sync() {
  local timeout="${1:-600}"
  local elapsed=0 response
  while true; do
    response="$(_action_rpc wallet get_sync_status '{}' 2>/dev/null || true)"
    jq -e '.synced == true' <<<"${response}" >/dev/null 2>&1 && return 0
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      _action_error "wallet synchronization timeout after ${timeout}s"
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

action_start_farming() {
  _action_require_role farmer
  action_start_services farmer-only
  action_start_services harvester
}

action_stop_farming() {
  _action_require_role farmer
  action_stop_services farmer-only
  action_stop_services harvester
}

action_mine_blocks() {
  local count="${1:-1}"
  local timeout="${2:-600}"
  local before
  _action_require_role farmer
  before="$(_action_peak_height)"
  action_start_farming
  action_wait_for_height "$((before + count))" "${timeout}"
}

action_connect_peer() {
  local host="${1:?peer host missing}"
  local port="${2:-8444}"
  _action_rpc full_node open_connection \
    "$(jq -cn --arg host "${host}" --argjson port "${port}" '{host:$host,port:$port}')" \
    >/dev/null
}

action_disconnect_peer() {
  local node_id="${1:?peer node ID missing}"
  _action_rpc full_node close_connection \
    "$(jq -cn --arg node_id "${node_id}" '{node_id:$node_id}')" \
    >/dev/null
}

action_new_address() {
  local wallet_id="${1:-1}"
  _action_rpc wallet get_next_address \
    "$(jq -cn --argjson wallet_id "${wallet_id}" '{wallet_id:$wallet_id,new_address:true}')" \
    | jq -er '.address'
}

action_send_transaction() {
  local address="${1:?destination address missing}"
  local amount="${2:?amount missing}"
  local fee="${3:-0}"
  local wallet_id="${4:-1}"
  local response transaction_id
  response="$(_action_rpc wallet send_transaction \
    "$(jq -cn --argjson wallet_id "${wallet_id}" --arg address "${address}" \
      --argjson amount "${amount}" --argjson fee "${fee}" \
      '{wallet_id:$wallet_id,address:$address,amount:$amount,fee:$fee,push:true}')")"
  transaction_id="$(jq -r '.transaction_id // .transaction.name // .transactions[0].name // empty' <<<"${response}")"
  [[ -n "${transaction_id}" ]] || {
    _action_error 'wallet returned no transaction ID'
    return 1
  }
  [[ "${transaction_id}" == 0x* ]] || transaction_id="0x${transaction_id}"
  ACTION_LAST_TRANSACTION_ID="${transaction_id}"
  export ACTION_LAST_TRANSACTION_ID
  printf '%s\n' "${transaction_id}"
}

action_send_to_self() {
  local amount="${1:-1000000}"
  local fee="${2:-0}"
  local wallet_id="${3:-1}"
  local address
  address="$(action_new_address "${wallet_id}")"
  action_send_transaction "${address}" "${amount}" "${fee}" "${wallet_id}"
}

action_wait_for_transaction() {
  local transaction_id="${1:-${ACTION_LAST_TRANSACTION_ID:-}}"
  local timeout="${2:-900}"
  local elapsed=0 response
  [[ -n "${transaction_id}" ]] || {
    _action_error 'transaction ID is required'
    return 1
  }
  while true; do
    response="$(_action_rpc wallet get_transaction \
      "$(jq -cn --arg transaction_id "${transaction_id}" '{transaction_id:$transaction_id}')" \
      2>/dev/null || true)"
    jq -e '.transaction.confirmed == true' <<<"${response}" >/dev/null 2>&1 && return 0
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      _action_error "transaction confirmation timeout after ${timeout}s"
      return 1
    fi
  done
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
  action_stop_services timelord-only
  action_stop_services timelord-launcher-only
}

action_start_vdf() {
  _action_require_role vdf
  action_start_services timelord-launcher-only
}

action_stop_vdf() {
  _action_require_role vdf
  action_stop_services timelord-launcher-only
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
  sia-signal serve "${port}" "${expected}" "${message}" "${timeout}"
}

action_signal_wait() {
  local host="${1:?server host missing}"
  local port="${2:?port missing}"
  local timeout="${3:-900}"
  sia-signal wait "${host}" "${port}" "${NODE_NAME:-node-unknown}" "${timeout}"
}

action_capture_next_block() {
  local parent_height="${1:?parent height missing}"
  local timeout="${2:-600}"
  local start now state height pid peak
  _action_require_role farmer

  start="$(date +%s)"
  while true; do
    state="$(_action_blockchain_state 2>/dev/null || true)"
    height="$(jq -r '.blockchain_state.peak.height // -1' <<<"${state}" 2>/dev/null || printf '%s' -1)"
    if [[ "${height}" =~ ^[0-9]+$ ]] && (( height > parent_height )); then
      peak="$(jq -c '.blockchain_state.peak' <<<"${state}")"
      pid="$(pgrep -o -x chia_full_node || true)"
      [[ -n "${pid}" ]] || {
        _action_error 'full-node process was not found'
        return 1
      }
      kill -STOP "${pid}"
      action_stop_farming
      ACTION_FROZEN_FULL_NODE_PID="${pid}"
      ACTION_CANDIDATE_HEIGHT="$(jq -r '.height' <<<"${peak}")"
      ACTION_CANDIDATE_HASH="$(jq -r '.header_hash' <<<"${peak}")"
      ACTION_CANDIDATE_PREV_HASH="$(jq -r '.prev_hash' <<<"${peak}")"
      ACTION_CANDIDATE_WEIGHT="$(jq -r '.weight' <<<"${peak}")"
      ACTION_CANDIDATE_TOTAL_ITERS="$(jq -r '.total_iters' <<<"${peak}")"
      export ACTION_FROZEN_FULL_NODE_PID ACTION_CANDIDATE_HEIGHT ACTION_CANDIDATE_HASH
      export ACTION_CANDIDATE_PREV_HASH ACTION_CANDIDATE_WEIGHT ACTION_CANDIDATE_TOTAL_ITERS
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      action_stop_farming
      _action_error "no new block after ${timeout}s"
      return 1
    fi
    sleep 0.02
  done
}

action_freeze_after_next_block() {
  local parent_height="${1:?parent height missing}"
  local timeout="${2:-600}"
  action_start_farming
  action_wait_for_plot 180
  action_capture_next_block "${parent_height}" "${timeout}"
}

action_finish_frozen_block() {
  local timeout="${1:-180}"
  local pid="${ACTION_FROZEN_FULL_NODE_PID:-}"
  local elapsed=0 state peak
  [[ -n "${pid}" ]] || {
    _action_error 'no suspended full-node process is recorded'
    return 1
  }

  kill -TERM "${pid}" >/dev/null 2>&1 || true
  kill -CONT "${pid}" >/dev/null 2>&1 || true
  while kill -0 "${pid}" >/dev/null 2>&1 && (( elapsed < 200 )); do
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -KILL "${pid}" >/dev/null 2>&1 || true
    sleep 1
  fi

  action_restart_services node
  action_wait_for_full_node_rpc "${timeout}"
  state="$(_action_blockchain_state)"
  peak="$(jq -c '.blockchain_state.peak' <<<"${state}")"
  ACTION_CANDIDATE_HEIGHT="$(jq -r '.height' <<<"${peak}")"
  ACTION_CANDIDATE_HASH="$(jq -r '.header_hash' <<<"${peak}")"
  ACTION_CANDIDATE_PREV_HASH="$(jq -r '.prev_hash' <<<"${peak}")"
  ACTION_CANDIDATE_WEIGHT="$(jq -r '.weight' <<<"${peak}")"
  ACTION_CANDIDATE_TOTAL_ITERS="$(jq -r '.total_iters' <<<"${peak}")"
  ACTION_FROZEN_FULL_NODE_PID=''
  export ACTION_FROZEN_FULL_NODE_PID ACTION_CANDIDATE_HEIGHT ACTION_CANDIDATE_HASH
  export ACTION_CANDIDATE_PREV_HASH ACTION_CANDIDATE_WEIGHT ACTION_CANDIDATE_TOTAL_ITERS
}
