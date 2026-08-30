#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/chia-blockchain/activate
source /workspace/controls/actions.sh

readonly SCENARIO="${1:-${SCENARIO:-}}"
readonly BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-1800}"
readonly BOOTSTRAP_READY_PORT=19001
readonly CHAIN_READY_PORT=19002
readonly BOOTSTRAP_DONE_PORT=19003
readonly SCENARIO_FILE="/workspace/scenarios/${NODE_NAME}_scenario${SCENARIO}.sh"
CHIA_LOG_TAIL_PID=''
CHAIN_READY_HEIGHT=''
CHAIN_READY_HASH=''

export CHIA_ROOT=/run/chia/root
export CHIA_KEYS_ROOT=/run/chia/keys

entry_error() {
  test_log ERROR entrypoint "$*"
}

entry_cleanup() {
  local status=$?
  trap - EXIT INT TERM
  pkill -CONT -f 'chia_(full_node|farmer|harvester|timelord)|vdf_client' >/dev/null 2>&1 || true
  timeout 20s chia stop -d all >/dev/null 2>&1 || true
  pkill -TERM -f 'chia_(full_node|farmer|harvester|timelord|daemon)|vdf_client' >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f 'chia_(full_node|farmer|harvester|timelord|daemon)|vdf_client' >/dev/null 2>&1 || true
  if [[ -n "${CHIA_LOG_TAIL_PID}" ]]; then
    kill "${CHIA_LOG_TAIL_PID}" >/dev/null 2>&1 || true
    wait "${CHIA_LOG_TAIL_PID}" >/dev/null 2>&1 || true
  fi
  exit "${status}"
}

entry_is_selected_node() {
  [[ ",${SCENARIO_NODES:-}," == *",${NODE_NAME},"* ]]
}

entry_peak_height() {
  _action_blockchain_state 2>/dev/null \
    | jq -r '.blockchain_state.peak.height // -1' 2>/dev/null \
    || printf '%s\n' -1
}

entry_peak_hash() {
  _action_blockchain_state 2>/dev/null \
    | jq -r '.blockchain_state.peak.header_hash // empty' 2>/dev/null \
    || true
}

entry_full_node_peer_count() {
  _action_rpc full_node get_connections '{}' 2>/dev/null \
    | jq -r '[.connections[]? | select(.type == 1)] | length' 2>/dev/null \
    || printf '%s\n' 0
}

entry_wait_for_full_node_peers() {
  local expected="${1:-2}"
  local timeout="${2:-180}"
  local elapsed=0 count=0
  while true; do
    count="$(entry_full_node_peer_count)"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count >= expected )); then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      entry_error "full-node peers=${count}; expected=${expected}"
      return 1
    fi
  done
}

entry_wait_for_shared_peak() {
  local target_height="${1:?target height missing}"
  local target_hash="${2:?target hash missing}"
  local timeout="${3:-900}"
  local start now height hash normalized_hash normalized_target
  normalized_target="${target_hash#0x}"
  normalized_target="${normalized_target,,}"
  start="$(date +%s)"
  while true; do
    height="$(entry_peak_height)"
    hash="$(entry_peak_hash)"
    normalized_hash="${hash#0x}"
    normalized_hash="${normalized_hash,,}"
    if [[ "${height}" == "${target_height}" && "${normalized_hash}" == "${normalized_target}" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      entry_error "peak convergence timeout: local=${height}/${hash:-none} target=${target_height}/${target_hash}"
      return 1
    fi
    sleep 0.2
  done
}

entry_stabilize_peak() {
  local timeout="${1:-30}"
  local elapsed=0 last=-2 stable=0 current
  while (( elapsed < timeout )); do
    current="$(entry_peak_height)"
    if [[ "${current}" == "${last}" ]]; then
      stable=$((stable + 1))
      (( stable < 3 )) || return 0
    else
      last="${current}"
      stable=0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

entry_setup_runtime() {
  local initial_address network_address
  rm -rf /run/chia
  mkdir -p "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" /run/chia/plots

  chia init >/dev/null 2>&1
  rm -rf "${CHIA_ROOT}/config/ssl"
  cp -a /opt/sia/node-ssl "${CHIA_ROOT}/config/ssl"
  chia keys add --filename /opt/sia/lab-mnemonic.txt --label private200 >/dev/null 2>&1
  chmod -R go-rwx "${CHIA_ROOT}/config/ssl" "${CHIA_KEYS_ROOT}" || true

  initial_address="$(chia keys show --json | jq -er '.keys[0].wallet_address')"
  sia-config "${CHIA_ROOT}/config/config.yaml" "${NODE_ID}" "${NODE_ROLE}" "${initial_address}"
  network_address="$(chia keys show --json | jq -er '.keys[0].wallet_address')"
  sia-config "${CHIA_ROOT}/config/config.yaml" "${NODE_ID}" "${NODE_ROLE}" "${network_address}"

  if [[ "${NODE_ROLE}" == farmer ]]; then
    find /opt/sia/plots -maxdepth 1 -type f -name '*.plot' -exec cp -a '{}' /run/chia/plots/ \;
  fi
}

entry_start_chia_log_stream() {
  mkdir -p "${CHIA_ROOT}/log"
  touch "${CHIA_ROOT}/log/debug.log"
  tail -n +1 -F "${CHIA_ROOT}/log/debug.log" &
  CHIA_LOG_TAIL_PID=$!
}

entry_start_bootstrap_services() {
  case "${NODE_ROLE}" in
    farmer)
      action_start_services node
      action_wait_for_full_node_rpc 240
      ;;
    timelord)
      action_start_timelord
      ;;
    vdf)
      action_start_vdf
      ;;
    *)
      entry_error "unsupported node role: ${NODE_ROLE}"
      return 1
      ;;
  esac
}

entry_bootstrap_ready_barrier() {
  local message
  if [[ "${NODE_NAME}" == node04 || "${NODE_NAME}" == node07 ]]; then
    action_wait_for_vdf_clients 3 420
  fi
  if [[ "${NODE_NAME}" == node01 ]]; then
    action_signal_serve "${BOOTSTRAP_READY_PORT}" 8 BOOTSTRAP_START "${BOOTSTRAP_TIMEOUT}" >/dev/null
    entry_wait_for_full_node_peers 2 180
  else
    message="$(action_signal_wait node01 "${BOOTSTRAP_READY_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_START ]] || {
      entry_error "unexpected bootstrap message: ${message}"
      return 1
    }
  fi
}

entry_verify_initial_chain() {
  local height="${1:?height missing}"
  local hash="${2:?hash missing}"
  local response
  if [[ ! "${height}" =~ ^[0-9]+$ ]] || (( height < 199 )); then
    entry_error "initial peak height is invalid: ${height}"
    return 1
  fi
  if [[ ! "${hash}" =~ ^(0x)?[0-9a-fA-F]{64}$ ]]; then
    entry_error "initial peak hash is invalid: ${hash:-empty}"
    return 1
  fi
  response="$(_action_rpc full_node get_block_record_by_height '{"height":199}' 2>/dev/null || true)"
  jq -e '.success == true and .block_record.height == 199' <<<"${response}" >/dev/null 2>&1 || {
    entry_error 'block record 199 is unavailable'
    return 1
  }
}

entry_build_initial_chain() {
  local height hash block_count
  action_start_farming
  action_wait_for_plot 240
  action_wait_for_height 199 "${BOOTSTRAP_TIMEOUT}"
  action_stop_farming
  entry_stabilize_peak 30

  height="$(entry_peak_height)"
  hash="$(entry_peak_hash)"
  entry_verify_initial_chain "${height}" "${hash}"
  block_count=$((height + 1))
  test_log INFO bootstrap \
    "INITIAL CHAIN READY: required_blocks=200 actual_blocks=${block_count} peak_height=${height} peak_hash=${hash}"
  action_signal_serve "${CHAIN_READY_PORT}" 8 "CHAIN_READY|${height}|${hash}" "${BOOTSTRAP_TIMEOUT}" >/dev/null
}

entry_receive_initial_chain() {
  local message marker extra
  message="$(action_signal_wait node01 "${CHAIN_READY_PORT}" "${BOOTSTRAP_TIMEOUT}")"
  IFS='|' read -r marker CHAIN_READY_HEIGHT CHAIN_READY_HASH extra <<<"${message}"
  if [[ "${marker}" != CHAIN_READY || -n "${extra:-}" ]]; then
    entry_error "invalid chain-ready message: ${message}"
    return 1
  fi
  export CHAIN_READY_HEIGHT CHAIN_READY_HASH
}

entry_stop_bootstrap_timing() {
  case "${NODE_ROLE}" in
    timelord) action_stop_timelord ;;
    vdf) action_stop_vdf ;;
    farmer) ;;
  esac
}

entry_bootstrap_done_barrier() {
  local message
  if [[ "${NODE_NAME}" == node01 ]]; then
    action_signal_serve "${BOOTSTRAP_DONE_PORT}" 8 BOOTSTRAP_DONE "${BOOTSTRAP_TIMEOUT}" >/dev/null
  else
    message="$(action_signal_wait node01 "${BOOTSTRAP_DONE_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_DONE ]] || {
      entry_error "unexpected bootstrap completion message: ${message}"
      return 1
    }
  fi
}

entry_run_scenario() {
  entry_is_selected_node || return 0
  if [[ ! -x "${SCENARIO_FILE}" ]]; then
    entry_error "scenario file is missing: ${SCENARIO_FILE}"
    return 66
  fi
  "${SCENARIO_FILE}"
}

main() {
  if [[ -z "${SCENARIO}" || ! "${SCENARIO}" =~ ^[0-9]+$ ]]; then
    entry_error 'a numeric scenario argument is required'
    return 64
  fi

  entry_setup_runtime
  entry_start_chia_log_stream
  entry_start_bootstrap_services
  entry_bootstrap_ready_barrier

  if [[ "${NODE_NAME}" == node01 ]]; then
    entry_build_initial_chain
  else
    entry_receive_initial_chain
    if [[ "${NODE_NAME}" == node02 || "${NODE_NAME}" == node03 ]]; then
      entry_wait_for_shared_peak "${CHAIN_READY_HEIGHT}" "${CHAIN_READY_HASH}" "${BOOTSTRAP_TIMEOUT}"
      entry_verify_initial_chain "${CHAIN_READY_HEIGHT}" "${CHAIN_READY_HASH}"
    fi
  fi

  entry_stop_bootstrap_timing
  entry_bootstrap_done_barrier
  entry_run_scenario
}

trap entry_cleanup EXIT INT TERM
main "$@"
