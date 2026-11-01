#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/actions.sh"

readonly LOCK_TIMEOUT="${LOCK_TIMEOUT:-1200}"
readonly LOCK_COORDINATOR="${LOCK_COORDINATOR:-node09}"
readonly LOCK_SUT="${LOCK_SUT:-node01}"
readonly LOCK_TIMELORD="${LOCK_TIMELORD:-node06}"
readonly LOCK_VDF="${LOCK_VDF:-node08}"
readonly LOCK_FULL_NODE_PORT=8444
readonly LOCK_FIXTURE_COUNT="${LOCK_FIXTURE_COUNT:-600}"
readonly LOCK_DONOR_BLOCKS="${LOCK_DONOR_BLOCKS:-16}"
readonly LOCK_CONTROL_SECONDS="${LOCK_CONTROL_SECONDS:-128}"
readonly LOCK_ATTACK_SECONDS="${LOCK_ATTACK_SECONDS:-128}"
readonly LOCK_RECOVERY_SECONDS="${LOCK_RECOVERY_SECONDS:-96}"
readonly LOCK_ATTACK_PRESSURE_SECONDS="${LOCK_ATTACK_PRESSURE_SECONDS:-32}"
readonly LOCK_ATTACK_INITIAL_BURST_SIZE="${LOCK_ATTACK_INITIAL_BURST_SIZE:-60}"
readonly LOCK_ATTACK_BURST_SIZE="${LOCK_ATTACK_BURST_SIZE:-10}"
readonly LOCK_ATTACK_BURST_INTERVAL_SECONDS="${LOCK_ATTACK_BURST_INTERVAL_SECONDS:-10}"
readonly LOCK_ATTACK_FINAL_BURST_SIZE="${LOCK_ATTACK_FINAL_BURST_SIZE:-10}"
readonly LOCK_ATTACK_FINAL_BURST_LEAD_MS="${LOCK_ATTACK_FINAL_BURST_LEAD_MS:-1000}"
readonly LOCK_MIN_CONTROL_FARMER_SAMPLES="${LOCK_MIN_CONTROL_FARMER_SAMPLES:-3}"
readonly LOCK_MIN_LOAD_FARMER_DECLARATIONS="${LOCK_MIN_LOAD_FARMER_DECLARATIONS:-2}"
readonly LOCK_MIN_CONTROL_BLOCKS="${LOCK_MIN_CONTROL_BLOCKS:-1}"
readonly LOCK_MIN_TRAFFIC_RATIO_PERCENT="${LOCK_MIN_TRAFFIC_RATIO_PERCENT:-95}"
readonly LOCK_MIN_RPC_RATIO_PERCENT="${LOCK_MIN_RPC_RATIO_PERCENT:-90}"
readonly LOCK_PHASE_LEAD_SECONDS="${LOCK_PHASE_LEAD_SECONDS:-8}"
readonly LOCK_VDF_CLIENTS="${VDF_CLIENTS_PER_TIMELORD:-3}"
readonly LOCK_FIXTURE_FILE=/run/chia/lock-fixtures.json
readonly LOCK_CONTROL_FILE=/run/chia/lock-control.json
readonly LOCK_ATTACK_FILE=/run/chia/lock-attack.json
readonly LOCK_RECOVERY_FILE=/run/chia/lock-recovery.json
readonly LOCK_HELPER="${LOCK_HELPER:-chia-lock-helper}"

readonly LOCK_CONTROL_SERVER_PORT=19201
readonly LOCK_CONTROL_TIMING_PORT=19202
readonly LOCK_CONTROL_START_PORT=19203
readonly LOCK_CONTROL_DONE_PORT=19204
readonly LOCK_TIMING_STOPPED_PORT=19205
readonly LOCK_PEAK_PORT=19206
readonly LOCK_PEAK_SYNC_PORT=19207
readonly LOCK_FIXTURES_READY_PORT=19208
readonly LOCK_ATTACKERS_STOPPED_PORT=19209
readonly LOCK_ATTACK_SERVER_PORT=19210
readonly LOCK_ATTACK_TIMING_PORT=19211
readonly LOCK_LOAD_START_PORT=19212
readonly LOCK_LOAD_DONE_PORT=19213
readonly LOCK_COMPLETE_PORT=19214
readonly LOCK_FIXTURE_DIGEST_PORT_BASE=19300

IFS=',' read -r -a LOCK_ATTACKER_NODES <<<"${LOCK_ATTACKERS:-node02,node03,node04}"
IFS=',' read -r -a LOCK_SCENARIO_NODES <<<"${SCENARIO_NODES:-node01,node02,node03,node04,node06,node07,node08,node09}"
readonly -a LOCK_ATTACKER_NODES LOCK_SCENARIO_NODES
LOCK_OTHER_NODE_COUNT=0
LOCK_PHASE_START_NS=0
LOCK_EXPECTED_ATTACK_MESSAGES=0

lock_error() {
  test_log ERROR lock-scenario "$*"
}

lock_contains() {
  local expected="${1:?value missing}"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == "${expected}" ]] && return 0
  done
  return 1
}

lock_validate_topology() {
  local value expected_role=''
  local -A seen=()

  (( ${#LOCK_ATTACKER_NODES[@]} >= 2 )) || {
    lock_error 'at least two traffic identities are required'
    return 1
  }
  for value in "${LOCK_SUT}" "${LOCK_COORDINATOR}" "${LOCK_TIMELORD}" "${LOCK_VDF}" "${LOCK_ATTACKER_NODES[@]}"; do
    lock_contains "${value}" "${LOCK_SCENARIO_NODES[@]}" || {
      lock_error "${value} is missing from SCENARIO_NODES"
      return 1
    }
  done
  for value in "${LOCK_ATTACKER_NODES[@]}"; do
    [[ "${value}" != "${LOCK_SUT}" && "${value}" != "${LOCK_COORDINATOR}" ]] || {
      lock_error "invalid traffic identity: ${value}"
      return 1
    }
  done
  for value in "${LOCK_SCENARIO_NODES[@]}"; do
    [[ -z "${seen[${value}]:-}" ]] || {
      lock_error "duplicate scenario node: ${value}"
      return 1
    }
    seen[${value}]=1
  done

  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]] || lock_contains "${NODE_NAME}" "${LOCK_ATTACKER_NODES[@]}"; then
    expected_role=farmer
  elif [[ "${NODE_NAME}" == "${LOCK_TIMELORD}" ]]; then
    expected_role=timelord
  elif [[ "${NODE_NAME}" == "${LOCK_VDF}" || "${NODE_NAME}" == "${LOCK_COORDINATOR}" ]]; then
    expected_role=vdf
  fi
  if [[ -n "${expected_role}" && "${NODE_ROLE}" != "${expected_role}" ]]; then
    lock_error "${NODE_NAME} has role ${NODE_ROLE}; expected ${expected_role}"
    return 1
  fi

  for value in "${LOCK_TIMEOUT}" "${LOCK_FIXTURE_COUNT}" "${LOCK_DONOR_BLOCKS}" \
      "${LOCK_CONTROL_SECONDS}" "${LOCK_ATTACK_SECONDS}" "${LOCK_RECOVERY_SECONDS}" \
      "${LOCK_ATTACK_PRESSURE_SECONDS}" \
      "${LOCK_ATTACK_INITIAL_BURST_SIZE}" "${LOCK_ATTACK_BURST_SIZE}" \
      "${LOCK_ATTACK_BURST_INTERVAL_SECONDS}" \
      "${LOCK_ATTACK_FINAL_BURST_SIZE}" "${LOCK_ATTACK_FINAL_BURST_LEAD_MS}" \
      "${LOCK_MIN_CONTROL_FARMER_SAMPLES}" "${LOCK_MIN_LOAD_FARMER_DECLARATIONS}" \
      "${LOCK_MIN_CONTROL_BLOCKS}" "${LOCK_MIN_TRAFFIC_RATIO_PERCENT}" \
      "${LOCK_MIN_RPC_RATIO_PERCENT}" "${LOCK_PHASE_LEAD_SECONDS}" "${LOCK_VDF_CLIENTS}"; do
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
      lock_error 'numeric scenario settings must be positive integers'
      return 1
    }
  done
  (( LOCK_FIXTURE_COUNT >= ${#LOCK_ATTACKER_NODES[@]} \
      && LOCK_DONOR_BLOCKS >= 4 \
      && LOCK_CONTROL_SECONDS >= 64 \
      && LOCK_ATTACK_SECONDS >= 64 \
      && LOCK_RECOVERY_SECONDS >= 32 \
      && LOCK_ATTACK_PRESSURE_SECONDS <= LOCK_ATTACK_SECONDS \
      && LOCK_ATTACK_FINAL_BURST_LEAD_MS < LOCK_ATTACK_SECONDS * 1000 \
      && LOCK_MIN_TRAFFIC_RATIO_PERCENT <= 100 \
      && LOCK_MIN_RPC_RATIO_PERCENT <= 100 \
      && LOCK_VDF_CLIENTS >= 3 )) || {
    lock_error 'fixture, donor, duration, or VDF settings are too small'
    return 1
  }

  LOCK_OTHER_NODE_COUNT=$((${#LOCK_SCENARIO_NODES[@]} - 1))

  local final_offset_ms=$((LOCK_ATTACK_SECONDS * 1000 - LOCK_ATTACK_FINAL_BURST_LEAD_MS))
  local regular_interval_ms=$((LOCK_ATTACK_BURST_INTERVAL_SECONDS * 1000))
  local regular_bursts=$(((final_offset_ms - 1) / regular_interval_ms))
  local per_sender=$((LOCK_ATTACK_INITIAL_BURST_SIZE \
    + regular_bursts * LOCK_ATTACK_BURST_SIZE + LOCK_ATTACK_FINAL_BURST_SIZE))
  local minimum_shard=$((LOCK_FIXTURE_COUNT / ${#LOCK_ATTACKER_NODES[@]}))
  (( per_sender <= minimum_shard )) || {
    lock_error "fixture count supplies ${minimum_shard} messages per sender, but burst schedule needs ${per_sender}"
    return 1
  }
  LOCK_EXPECTED_ATTACK_MESSAGES=$((per_sender * ${#LOCK_ATTACKER_NODES[@]}))
}

lock_barrier() {
  local port="${1:?barrier port missing}"
  local expected="${2:?barrier message missing}"
  local received
  if [[ "${NODE_NAME}" == "${LOCK_COORDINATOR}" ]]; then
    action_signal_serve "${port}" "${LOCK_OTHER_NODE_COUNT}" "${expected}" "${LOCK_TIMEOUT}" >/dev/null
  else
    received="$(action_signal_wait "${LOCK_COORDINATOR}" "${port}" "${LOCK_TIMEOUT}")"
    [[ "${received}" == "${expected}" ]] || {
      lock_error "unexpected barrier message on ${port}: ${received}"
      return 1
    }
  fi
}

lock_phase_start() {
  local port="${1:?start port missing}"
  local phase="${2:?phase missing}"
  local message marker received_phase start_ns extra
  if [[ "${NODE_NAME}" == "${LOCK_COORDINATOR}" ]]; then
    LOCK_PHASE_START_NS=$(( $(date +%s%N) + LOCK_PHASE_LEAD_SECONDS * 1000000000 ))
    test_log INFO lock-scenario "scheduling ${phase} phase"
    message="START|${phase}|${LOCK_PHASE_START_NS}"
    action_signal_serve "${port}" "${LOCK_OTHER_NODE_COUNT}" "${message}" "${LOCK_TIMEOUT}" >/dev/null
  else
    message="$(action_signal_wait "${LOCK_COORDINATOR}" "${port}" "${LOCK_TIMEOUT}")"
    IFS='|' read -r marker received_phase start_ns extra <<<"${message}"
    [[ "${marker}" == START && "${received_phase}" == "${phase}" \
       && "${start_ns}" =~ ^[0-9]+$ && -z "${extra:-}" ]] || {
      lock_error "invalid phase-start message: ${message}"
      return 1
    }
    LOCK_PHASE_START_NS="${start_ns}"
  fi
  export LOCK_PHASE_START_NS
}

lock_wait_until_ns() {
  local target="${1:?target time missing}" now remaining
  while true; do
    now="$(date +%s%N)"
    remaining=$((target - now))
    (( remaining <= 0 )) && return 0
    if (( remaining > 100000000 )); then sleep 0.05; else sleep 0.005; fi
  done
}

lock_wait_phase_end() {
  local start_ns="${1:?start time missing}"
  local duration="${2:?duration missing}"
  lock_wait_until_ns $((start_ns + duration * 1000000000))
}

lock_start_timing() {
  local server_port="${1:?server barrier port missing}"
  local ready_port="${2:?ready barrier port missing}"
  local label="${3:?timing label missing}"

  if [[ "${NODE_NAME}" == "${LOCK_TIMELORD}" ]]; then
    action_start_timelord_server
    action_wait_for_vdf_server 180
  fi
  lock_barrier "${server_port}" "TIMELORD_SERVER_READY|${label}"

  if [[ "${NODE_NAME}" == "${LOCK_TIMELORD}" ]]; then
    action_start_timelord_vdf
    action_wait_for_vdf_clients "${LOCK_VDF_CLIENTS}" "${LOCK_TIMEOUT}"
  elif [[ "${NODE_NAME}" == "${LOCK_VDF}" ]]; then
    action_start_vdf
  elif [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    action_start_farming
    action_wait_for_plot 180
  fi
  lock_barrier "${ready_port}" "TIMING_READY|${label}"
}

lock_stop_timing() {
  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    action_stop_farming
  elif [[ "${NODE_NAME}" == "${LOCK_TIMELORD}" ]]; then
    action_stop_timelord
  elif [[ "${NODE_NAME}" == "${LOCK_VDF}" ]]; then
    action_stop_vdf
  fi
  lock_barrier "${LOCK_TIMING_STOPPED_PORT}" 'TIMING_STOPPED'
}

lock_run_control_phase() {
  lock_phase_start "${LOCK_CONTROL_START_PORT}" control
  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    "${LOCK_HELPER}" monitor \
      --log "${CHIA_ROOT}/log/debug.log" \
      --output "${LOCK_CONTROL_FILE}" \
      --start-at-ns "${LOCK_PHASE_START_NS}" \
      --duration "${LOCK_CONTROL_SECONDS}" \
      --phase control
  else
    lock_wait_phase_end "${LOCK_PHASE_START_NS}" "${LOCK_CONTROL_SECONDS}"
  fi
  lock_barrier "${LOCK_CONTROL_DONE_PORT}" 'PHASE_DONE|control'
}

lock_wait_for_stable_peak() {
  local stable=0 previous='' current attempts=0
  while (( attempts < 60 )); do
    current="$(_action_peak_hash 2>/dev/null || true)"
    if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
      stable=$((stable + 1))
      (( stable >= 5 )) && return 0
    else
      previous="${current}"
      stable=0
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  lock_error 'peak did not stabilize after timing was stopped'
  return 1
}

lock_synchronize_fixture_peaks() {
  local message marker height hash extra
  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    lock_wait_for_stable_peak
    height="$(_action_peak_height)"
    hash="$(_action_peak_hash)"
    action_signal_serve "${LOCK_PEAK_PORT}" "${#LOCK_ATTACKER_NODES[@]}" \
      "PEAK|${height}|${hash}" "${LOCK_TIMEOUT}" >/dev/null
  elif lock_contains "${NODE_NAME}" "${LOCK_ATTACKER_NODES[@]}"; then
    message="$(action_signal_wait "${LOCK_SUT}" "${LOCK_PEAK_PORT}" "${LOCK_TIMEOUT}")"
    IFS='|' read -r marker height hash extra <<<"${message}"
    [[ "${marker}" == PEAK && "${height}" =~ ^[0-9]+$ \
       && "${hash}" =~ ^(0x)?[0-9a-fA-F]{64}$ && -z "${extra:-}" ]] || {
      lock_error "invalid peak message: ${message}"
      return 1
    }
    action_wait_for_peak_hash "${hash}" "${LOCK_TIMEOUT}"
  fi
  lock_barrier "${LOCK_PEAK_SYNC_PORT}" 'FIXTURE_PEAKS_SYNCHRONIZED'
}

lock_attacker_index() {
  local index
  for index in "${!LOCK_ATTACKER_NODES[@]}"; do
    if [[ "${LOCK_ATTACKER_NODES[index]}" == "${NODE_NAME}" ]]; then
      printf '%s\n' "${index}"
      return 0
    fi
  done
  return 1
}

lock_generate_and_verify_fixtures() {
  local index port digest message marker received_digest extra first_digest=''
  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]] || lock_contains "${NODE_NAME}" "${LOCK_ATTACKER_NODES[@]}"; then
    if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
      test_log INFO lock-scenario 'building deterministic signage-point fixtures'
    fi
    bash /workspace/controls/lock-traffic.sh make-fixtures \
      --output "${LOCK_FIXTURE_FILE}" \
      --attack-count "${LOCK_FIXTURE_COUNT}" \
      --donor-blocks "${LOCK_DONOR_BLOCKS}"
    digest="$(jq -er '.fixture_sha256' "${LOCK_FIXTURE_FILE}")"
    if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
      index="${#LOCK_ATTACKER_NODES[@]}"
    else
      index="$(lock_attacker_index)"
    fi
    port=$((LOCK_FIXTURE_DIGEST_PORT_BASE + index))
    action_signal_serve "${port}" 1 "FIXTURE|${digest}" "${LOCK_TIMEOUT}" >/dev/null
  elif [[ "${NODE_NAME}" == "${LOCK_COORDINATOR}" ]]; then
    local -a fixture_nodes=("${LOCK_ATTACKER_NODES[@]}" "${LOCK_SUT}")
    for index in "${!fixture_nodes[@]}"; do
      port=$((LOCK_FIXTURE_DIGEST_PORT_BASE + index))
      message="$(action_signal_wait "${fixture_nodes[index]}" "${port}" "${LOCK_TIMEOUT}")"
      IFS='|' read -r marker received_digest extra <<<"${message}"
      [[ "${marker}" == FIXTURE && "${received_digest}" =~ ^[0-9a-f]{64}$ && -z "${extra:-}" ]] || {
        lock_error "invalid fixture digest message: ${message}"
        return 1
      }
      if [[ -z "${first_digest}" ]]; then
        first_digest="${received_digest}"
      elif [[ "${received_digest}" != "${first_digest}" ]]; then
        lock_error 'fixture generation/context differed between participants'
        return 1
      fi
    done
  fi
  lock_barrier "${LOCK_FIXTURES_READY_PORT}" 'FIXTURES_VERIFIED'
}

lock_stop_attacker_full_nodes() {
  local attempts=0
  if lock_contains "${NODE_NAME}" "${LOCK_ATTACKER_NODES[@]}"; then
    action_stop_services node
    while pgrep -x chia_full_node >/dev/null 2>&1; do
      attempts=$((attempts + 1))
      (( attempts < 450 )) || {
        lock_error 'traffic-source full node did not stop'
        return 1
      }
      sleep 0.1
    done
  fi
  lock_barrier "${LOCK_ATTACKERS_STOPPED_PORT}" 'TRAFFIC_SOURCE_FULL_NODES_STOPPED'
  sleep 3
}

lock_send_attack() {
  local index
  index="$(lock_attacker_index)"
  bash /workspace/controls/lock-traffic.sh send-set \
    --fixtures "${LOCK_FIXTURE_FILE}" \
    --fixture-set attack \
    --target "${LOCK_SUT}" \
    --port "${LOCK_FULL_NODE_PORT}" \
    --start-at-ns "${LOCK_PHASE_START_NS}" \
    --shard-index "${index}" \
    --shard-count "${#LOCK_ATTACKER_NODES[@]}" \
    --initial-burst-size "${LOCK_ATTACK_INITIAL_BURST_SIZE}" \
    --burst-size "${LOCK_ATTACK_BURST_SIZE}" \
    --burst-interval-seconds "${LOCK_ATTACK_BURST_INTERVAL_SECONDS}" \
    --final-burst-size "${LOCK_ATTACK_FINAL_BURST_SIZE}" \
    --final-burst-lead-ms "${LOCK_ATTACK_FINAL_BURST_LEAD_MS}" \
    --duration "${LOCK_ATTACK_SECONDS}" \
    --settle-seconds 1
}

lock_run_load_and_recovery() {
  local total_seconds=$((LOCK_ATTACK_SECONDS + LOCK_RECOVERY_SECONDS))
  local recovery_start_ns=$((LOCK_PHASE_START_NS + LOCK_ATTACK_SECONDS * 1000000000))

  lock_phase_start "${LOCK_LOAD_START_PORT}" load
  recovery_start_ns=$((LOCK_PHASE_START_NS + LOCK_ATTACK_SECONDS * 1000000000))

  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    "${LOCK_HELPER}" monitor \
      --log "${CHIA_ROOT}/log/debug.log" \
      --output "${LOCK_ATTACK_FILE}" \
      --start-at-ns "${LOCK_PHASE_START_NS}" \
      --duration "${LOCK_ATTACK_SECONDS}" \
      --pressure-window-seconds "${LOCK_ATTACK_PRESSURE_SECONDS}" \
      --phase attack
    "${LOCK_HELPER}" monitor \
      --log "${CHIA_ROOT}/log/debug.log" \
      --output "${LOCK_RECOVERY_FILE}" \
      --start-at-ns "${recovery_start_ns}" \
      --duration "${LOCK_RECOVERY_SECONDS}" \
      --phase recovery
  elif lock_contains "${NODE_NAME}" "${LOCK_ATTACKER_NODES[@]}"; then
    lock_send_attack
    lock_wait_phase_end "${LOCK_PHASE_START_NS}" "${total_seconds}"
  else
    lock_wait_phase_end "${LOCK_PHASE_START_NS}" "${total_seconds}"
  fi

  lock_barrier "${LOCK_LOAD_DONE_PORT}" 'PHASE_DONE|load_and_recovery'
}

lock_build_version() {
  chia version 2>/dev/null | head -n 1 | tr -d '\r\n' || printf 'unknown'
}

lock_build_fingerprint() {
  local temporary
  temporary="$(mktemp)"
  find /opt/chia-blockchain -type f \
    \( -path '*/chia/full_node/full_node_api.py' \
       -o -path '*/chia/full_node/full_node.py' \
       -o -path '*/chia/full_node/full_node_store.py' \
       -o -path '*/bin/chia' \
       -o -path '*/bin/chia_full_node' \) \
    -print0 2>/dev/null \
    | sort -z \
    | xargs -0 -r sha256sum >"${temporary}"
  if [[ -s "${temporary}" ]]; then
    sha256sum "${temporary}" | awk '{print $1}'
  else
    sha256sum "$(command -v chia)" | awk '{print $1}'
  fi
  rm -f "${temporary}"
}

lock_write_behavior_report() {
  local final_state version fingerprint fixture_digest report_status=0
  version="$(lock_build_version)"
  fingerprint="$(lock_build_fingerprint)"
  fixture_digest="$(jq -er '.fixture_sha256' "${LOCK_FIXTURE_FILE}")"
  "${LOCK_HELPER}" report \
    --control "${LOCK_CONTROL_FILE}" \
    --attack "${LOCK_ATTACK_FILE}" \
    --recovery "${LOCK_RECOVERY_FILE}" \
    --build-version "${version}" \
    --build-fingerprint "${fingerprint}" \
    --package-sha256 "${CHIA_BINARY_PACKAGE_SHA256:-unknown}" \
    --fixture-sha256 "${fixture_digest}" \
    --expected-attack-messages "${LOCK_EXPECTED_ATTACK_MESSAGES}" \
    --min-control-farmer-samples "${LOCK_MIN_CONTROL_FARMER_SAMPLES}" \
    --min-load-farmer-declarations "${LOCK_MIN_LOAD_FARMER_DECLARATIONS}" \
    --min-control-blocks "${LOCK_MIN_CONTROL_BLOCKS}" \
    --min-traffic-ratio-percent "${LOCK_MIN_TRAFFIC_RATIO_PERCENT}" \
    --min-rpc-ratio-percent "${LOCK_MIN_RPC_RATIO_PERCENT}" \
    --output /run/chia/lock-result.json || report_status=$?

  local result_tmp=/run/chia/lock-result.json.tmp
  if final_state="$(_action_blockchain_state)" && jq -e '.success == true' <<<"${final_state}" >/dev/null; then
    jq --argjson state "$(jq -c '{peak_height:.blockchain_state.peak.height,peak_hash:.blockchain_state.peak.header_hash}' <<<"${final_state}")" \
      '.final_rpc_state = $state' /run/chia/lock-result.json >"${result_tmp}"
  else
    jq '.final_rpc_state = null' /run/chia/lock-result.json >"${result_tmp}"
  fi
  mv "${result_tmp}" /run/chia/lock-result.json
  if (( report_status != 0 )); then
    lock_error "measurement validity checks failed; see lock-result.json"
    return "${report_status}"
  fi
}

lock_scenario_main() {
  local report_status=0
  lock_validate_topology

  lock_start_timing "${LOCK_CONTROL_SERVER_PORT}" "${LOCK_CONTROL_TIMING_PORT}" control
  lock_run_control_phase
  lock_stop_timing

  lock_synchronize_fixture_peaks
  lock_generate_and_verify_fixtures
  lock_stop_attacker_full_nodes

  lock_start_timing "${LOCK_ATTACK_SERVER_PORT}" "${LOCK_ATTACK_TIMING_PORT}" load
  lock_run_load_and_recovery

  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    lock_write_behavior_report || report_status=$?
    test_log INFO lock-scenario 'behavior report written; stopping scenario services'
  fi

  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]]; then
    action_stop_farming
  elif [[ "${NODE_NAME}" == "${LOCK_TIMELORD}" ]]; then
    action_stop_timelord
  elif [[ "${NODE_NAME}" == "${LOCK_VDF}" ]]; then
    action_stop_vdf
  fi
  lock_barrier "${LOCK_COMPLETE_PORT}" 'done'
  if [[ "${NODE_NAME}" == "${LOCK_SUT}" ]] && (( report_status != 0 )); then
    return "${report_status}"
  fi
}
