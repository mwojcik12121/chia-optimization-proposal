#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/chia-blockchain/activate
source /workspace/controls/actions.sh

readonly SCENARIO="${1:-${SCENARIO:-}}"
readonly BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-2700}"
readonly BOOTSTRAP_TARGET_HEIGHT="${BOOTSTRAP_TARGET_HEIGHT:-129}"
readonly BOOTSTRAP_SOLO_BLOCKS="${BOOTSTRAP_SOLO_BLOCKS:-3}"
readonly FARMER_NODES="${FARMER_NODES:-node01,node02,node03,node04}"
readonly TIMELORD_NODES="${TIMELORD_NODES:-node06,node07}"
readonly VDF_CLIENTS_PER_TIMELORD="${VDF_CLIENTS_PER_TIMELORD:-3}"
readonly BOOTSTRAP_TIMELORD="${LOCK_TIMELORD:-node06}"
readonly BOOTSTRAP_VDF="${LOCK_VDF:-node08}"
readonly BOOTSTRAP_READY_PORT=19001
readonly BOOTSTRAP_FARMING_READY_PORT=19002
readonly BOOTSTRAP_SOLO_PORT=19003
readonly BOOTSTRAP_SOLO_READY_PORT=19004
readonly BOOTSTRAP_STOP_PORT=19005
readonly BOOTSTRAP_STOPPED_PORT=19006
readonly CHAIN_READY_PORT=19007
readonly BOOTSTRAP_DONE_PORT=19008
readonly SCENARIO_FILE="/workspace/scenarios/${NODE_NAME}_scenario${SCENARIO}.sh"
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
  timeout 60s chia stop -d all >/dev/null 2>&1 || true
  # The application may spend 30s draining validation/publication. The CLI can
  # return before its children, so wait for them before forcing termination.
  local deadline=$((SECONDS + 45))
  while pgrep -f 'chia_(full_node|farmer|harvester|timelord|daemon)|vdf_client' >/dev/null 2>&1 \
      && (( SECONDS < deadline )); do
    sleep 0.2
  done
  pkill -TERM -f 'chia_(full_node|farmer|harvester|timelord|daemon)|vdf_client' >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f 'chia_(full_node|farmer|harvester|timelord|daemon)|vdf_client' >/dev/null 2>&1 || true
  exit "${status}"
}

entry_is_selected_node() {
  [[ ",${SCENARIO_NODES:-}," == *",${NODE_NAME},"* ]]
}

entry_csv_contains() {
  local values="${1:-}"
  local value="${2:?value missing}"
  [[ ",${values}," == *",${value},"* ]]
}

entry_csv_count() {
  local values="${1:-}"
  local -a items=()
  [[ -n "${values}" ]] || {
    printf '%s\n' 0
    return 0
  }
  IFS=',' read -r -a items <<<"${values}"
  printf '%s\n' "${#items[@]}"
}

entry_other_node_count() {
  local count
  count="$(entry_csv_count "${SCENARIO_NODES:-}")"
  (( count > 0 )) || {
    entry_error 'SCENARIO_NODES must contain at least one node'
    return 1
  }
  printf '%s\n' "$((count - 1))"
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
  local timeout="${1:-90}"
  local elapsed=0 previous='' stable=0 current
  while (( elapsed < timeout )); do
    current="$(entry_peak_hash)"
    if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
      stable=$((stable + 1))
      (( stable >= 5 )) && return 0
    else
      previous="${current}"
      stable=0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  entry_error "peak did not stabilize within ${timeout}s"
  return 1
}

entry_wait_for_height_with_progress() {
  local label="${1:?label missing}"
  local target="${2:?target height missing}"
  local timeout="${3:-600}"
  local start now elapsed=0 height=-1 next_report=0
  start="$(date +%s)"
  while true; do
    height="$(entry_peak_height)"
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= next_report )); then
      test_log INFO bootstrap         "${label}: height=${height}/${target} elapsed=${elapsed}s"
      next_report=$((next_report + 30))
    fi
    if [[ "${height}" =~ ^[0-9]+$ ]] && (( height >= target )); then
      return 0
    fi
    if (( elapsed >= timeout )); then
      entry_error "${label}: height ${target} was not reached; current=${height}"
      return 1
    fi
    sleep 0.5
  done
}

entry_setup_runtime() {
  local initial_address network_address
  rm -rf /run/chia
  mkdir -p "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" /run/chia/plots

  chia init >/dev/null 2>&1
  rm -rf "${CHIA_ROOT}/config/ssl"
  cp -a /opt/chia/node-ssl "${CHIA_ROOT}/config/ssl"
  chia keys add --filename /opt/chia/lab-mnemonic.txt --label private200 >/dev/null 2>&1
  chmod -R go-rwx "${CHIA_ROOT}/config/ssl" "${CHIA_KEYS_ROOT}" || true

  initial_address="$(chia keys show --json | jq -er '.keys[0].wallet_address')"
  chia-config "${CHIA_ROOT}/config/config.yaml" "${NODE_ID}" "${NODE_ROLE}" "${initial_address}"
  network_address="$(chia keys show --json | jq -er '.keys[0].wallet_address')"
  chia-config "${CHIA_ROOT}/config/config.yaml" "${NODE_ID}" "${NODE_ROLE}" "${network_address}"
  "${LOCK_HELPER:-chia-lock-helper}" config --config "${CHIA_ROOT}/config/config.yaml"

  if [[ "${NODE_ROLE}" == farmer ]]; then
    find /opt/chia/plots -maxdepth 1 -type f -name '*.plot' -exec cp -a '{}' /run/chia/plots/ \;
  fi
}

entry_start_bootstrap_services() {
  case "${NODE_ROLE}" in
    farmer)
      action_start_services node
      action_wait_for_full_node_rpc 240
      ;;
    timelord)
      if [[ "${NODE_NAME}" == "${BOOTSTRAP_TIMELORD}" ]]; then
        action_start_timelord_server
        action_wait_for_vdf_server 180
      fi
      ;;
    vdf) ;;
    *)
      entry_error "unsupported node role: ${NODE_ROLE}"
      return 1
      ;;
  esac
}

entry_bootstrap_ready_barrier() {
  local message expected_peers other_nodes
  if [[ ! "${VDF_CLIENTS_PER_TIMELORD}" =~ ^([3-9]|[1-9][0-9]+)$ ]]; then
    entry_error 'VDF_CLIENTS_PER_TIMELORD must be an integer of at least three'
    return 1
  fi
  if [[ "${NODE_NAME}" == node01 ]]; then
    other_nodes="$(entry_other_node_count)"
    expected_peers=$(( $(entry_csv_count "${FARMER_NODES}") - 1 ))
    entry_wait_for_full_node_peers "${expected_peers}" 180
    action_signal_serve \
      "${BOOTSTRAP_READY_PORT}" "${other_nodes}" BOOTSTRAP_START "${BOOTSTRAP_TIMEOUT}" >/dev/null
  else
    message="$(action_signal_wait node01 "${BOOTSTRAP_READY_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_START ]] || {
      entry_error "unexpected bootstrap message: ${message}"
      return 1
    }
  fi

  # Start VDF launchers only after the timelord server and all full nodes are
  # ready. This avoids startup races and keeps the second timing group idle.
  if [[ "${NODE_NAME}" == "${BOOTSTRAP_TIMELORD}" ]]; then
    action_start_timelord_vdf
  elif [[ "${NODE_NAME}" == "${BOOTSTRAP_VDF}" ]]; then
    action_start_vdf
  fi
}

entry_start_bootstrap_farming() {
  local message other_nodes
  if entry_csv_contains "${FARMER_NODES}" "${NODE_NAME}"; then
    action_start_farming
    action_wait_for_plot 240
  fi
  if [[ "${NODE_NAME}" == "${BOOTSTRAP_TIMELORD}" ]]; then
    action_wait_for_vdf_clients "${VDF_CLIENTS_PER_TIMELORD}" 420
  fi

  if [[ "${NODE_NAME}" == node01 ]]; then
    other_nodes="$(entry_other_node_count)"
    action_signal_serve \
      "${BOOTSTRAP_FARMING_READY_PORT}" "${other_nodes}" BOOTSTRAP_FARMING_READY \
      "${BOOTSTRAP_TIMEOUT}" >/dev/null
    test_log INFO bootstrap \
      "all bootstrap participants are ready; parallel farming to height $((BOOTSTRAP_TARGET_HEIGHT - BOOTSTRAP_SOLO_BLOCKS))"
  else
    message="$(action_signal_wait node01 "${BOOTSTRAP_FARMING_READY_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_FARMING_READY ]] || {
      entry_error "unexpected farming-ready message: ${message}"
      return 1
    }
  fi
}

entry_stop_bootstrap_services() {
  case "${NODE_ROLE}" in
    farmer) action_stop_farming ;;
    timelord)
      if [[ "${NODE_NAME}" == "${BOOTSTRAP_TIMELORD}" ]]; then
        action_stop_timelord
      fi
      ;;
    vdf)
      if [[ "${NODE_NAME}" == "${BOOTSTRAP_VDF}" ]]; then
        action_stop_vdf
      fi
      ;;
  esac
}

entry_build_initial_chain() {
  local parallel_target=$((BOOTSTRAP_TARGET_HEIGHT - BOOTSTRAP_SOLO_BLOCKS))
  entry_wait_for_height_with_progress parallel-bootstrap "${parallel_target}" "${BOOTSTRAP_TIMEOUT}"
  test_log INFO bootstrap "parallel bootstrap height ${parallel_target} reached"
}

entry_finish_with_single_farmer() {
  local message other_nodes solo_start final_target
  if [[ "${NODE_NAME}" == node01 ]]; then
    other_nodes="$(entry_other_node_count)"
    action_signal_serve \
      "${BOOTSTRAP_SOLO_PORT}" "${other_nodes}" BOOTSTRAP_SOLO "${BOOTSTRAP_TIMEOUT}" >/dev/null
    action_signal_serve \
      "${BOOTSTRAP_SOLO_READY_PORT}" "${other_nodes}" BOOTSTRAP_SOLO_READY \
      "${BOOTSTRAP_TIMEOUT}" >/dev/null

    solo_start="$(entry_peak_height)"
    [[ "${solo_start}" =~ ^[0-9]+$ ]] || {
      entry_error "invalid solo-farming start height: ${solo_start}"
      return 1
    }
    final_target=$((solo_start + BOOTSTRAP_SOLO_BLOCKS))
    (( final_target >= BOOTSTRAP_TARGET_HEIGHT )) || final_target="${BOOTSTRAP_TARGET_HEIGHT}"
    test_log INFO bootstrap \
      "other farmers stopped at height ${solo_start}; node01 farming to ${final_target}"
    entry_wait_for_height_with_progress solo-bootstrap "${final_target}" "${BOOTSTRAP_TIMEOUT}"
    test_log INFO bootstrap "solo finishing height reached; stopping bootstrap producers"
  else
    message="$(action_signal_wait node01 "${BOOTSTRAP_SOLO_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_SOLO ]] || {
      entry_error "unexpected solo-bootstrap message: ${message}"
      return 1
    }
    if [[ "${NODE_ROLE}" == farmer && "${NODE_NAME}" != node01 ]]; then
      action_stop_farming
    fi
    message="$(action_signal_wait node01 "${BOOTSTRAP_SOLO_READY_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_SOLO_READY ]] || {
      entry_error "unexpected solo-bootstrap-ready message: ${message}"
      return 1
    }
  fi
}

entry_freeze_bootstrap() {
  local message other_nodes
  if [[ "${NODE_NAME}" == node01 ]]; then
    entry_stop_bootstrap_services
    other_nodes="$(entry_other_node_count)"
    action_signal_serve \
      "${BOOTSTRAP_STOP_PORT}" "${other_nodes}" BOOTSTRAP_STOP "${BOOTSTRAP_TIMEOUT}" >/dev/null
    action_signal_serve \
      "${BOOTSTRAP_STOPPED_PORT}" "${other_nodes}" BOOTSTRAP_STOPPED "${BOOTSTRAP_TIMEOUT}" >/dev/null
  else
    message="$(action_signal_wait node01 "${BOOTSTRAP_STOP_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_STOP ]] || {
      entry_error "unexpected bootstrap-stop message: ${message}"
      return 1
    }
    entry_stop_bootstrap_services
    message="$(action_signal_wait node01 "${BOOTSTRAP_STOPPED_PORT}" "${BOOTSTRAP_TIMEOUT}")"
    [[ "${message}" == BOOTSTRAP_STOPPED ]] || {
      entry_error "unexpected bootstrap-stopped message: ${message}"
      return 1
    }
  fi
}

entry_verify_initial_chain() {
  local height="${1:?height missing}"
  local hash="${2:?hash missing}"
  local response
  if [[ ! "${height}" =~ ^[0-9]+$ ]] || (( height < BOOTSTRAP_TARGET_HEIGHT )); then
    entry_error "initial peak height is invalid: ${height}; minimum=${BOOTSTRAP_TARGET_HEIGHT}"
    return 1
  fi
  if [[ ! "${hash}" =~ ^(0x)?[0-9a-fA-F]{64}$ ]]; then
    entry_error "initial peak hash is invalid: ${hash:-empty}"
    return 1
  fi
  response="$(_action_rpc full_node get_block_record_by_height \
    "$(jq -cn --argjson height "${height}" '{height:$height}')" 2>/dev/null || true)"
  jq -e --argjson height "${height}" \
    '.success == true and .block_record.height == $height' <<<"${response}" >/dev/null 2>&1 || {
    entry_error "block record ${height} is unavailable"
    return 1
  }
}

entry_publish_initial_chain() {
  local height hash other_nodes
  entry_stabilize_peak 90
  height="$(entry_peak_height)"
  hash="$(entry_peak_hash)"
  entry_verify_initial_chain "${height}" "${hash}"
  test_log INFO bootstrap "stable bootstrap peak height=${height} hash=${hash}"
  other_nodes="$(entry_other_node_count)"
  action_signal_serve \
    "${CHAIN_READY_PORT}" "${other_nodes}" "CHAIN_READY|${height}|${hash}" \
    "${BOOTSTRAP_TIMEOUT}" >/dev/null
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

entry_bootstrap_done_barrier() {
  local message other_nodes
  if [[ "${NODE_NAME}" == node01 ]]; then
    other_nodes="$(entry_other_node_count)"
    action_signal_serve \
      "${BOOTSTRAP_DONE_PORT}" "${other_nodes}" BOOTSTRAP_DONE "${BOOTSTRAP_TIMEOUT}" >/dev/null
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
  if [[ ! "${BOOTSTRAP_TARGET_HEIGHT}" =~ ^[0-9]+$ ]] || (( BOOTSTRAP_TARGET_HEIGHT < 129 )); then
    entry_error 'BOOTSTRAP_TARGET_HEIGHT must be an integer of at least 129'
    return 64
  fi
  if [[ ! "${BOOTSTRAP_SOLO_BLOCKS}" =~ ^[1-9][0-9]*$ ]] \
      || (( BOOTSTRAP_SOLO_BLOCKS >= BOOTSTRAP_TARGET_HEIGHT )); then
    entry_error 'BOOTSTRAP_SOLO_BLOCKS must be a positive integer below BOOTSTRAP_TARGET_HEIGHT'
    return 64
  fi

  entry_setup_runtime
  entry_start_bootstrap_services
  entry_bootstrap_ready_barrier
  entry_start_bootstrap_farming

  if [[ "${NODE_NAME}" == node01 ]]; then
    entry_build_initial_chain
  fi

  entry_finish_with_single_farmer
  entry_freeze_bootstrap

  if [[ "${NODE_NAME}" == node01 ]]; then
    entry_publish_initial_chain
  else
    entry_receive_initial_chain
    if entry_csv_contains "${FARMER_NODES}" "${NODE_NAME}"; then
      entry_wait_for_shared_peak "${CHAIN_READY_HEIGHT}" "${CHAIN_READY_HASH}" "${BOOTSTRAP_TIMEOUT}"
      entry_verify_initial_chain "${CHAIN_READY_HEIGHT}" "${CHAIN_READY_HASH}"
    fi
  fi

  entry_bootstrap_done_barrier
  if [[ "${NODE_NAME}" == node01 ]]; then
    test_log INFO bootstrap 'bootstrap complete; starting Scenario 1'
  fi
  entry_run_scenario
}

trap entry_cleanup EXIT INT TERM
main "$@"
