#!/usr/bin/env bash
set -Eeuo pipefail

source /workspace/controls/actions.sh
source /workspace/controls/network.sh

readonly TIE_TIMEOUT="${TIE_TIMEOUT:-1200}"
readonly TIE_PARTITION_PORT=19101
readonly TIE_TIMING_READY_PORT=19102
readonly TIE_STOP_A_PORT=19111
readonly TIE_STOP_B_PORT=19112
readonly TIE_STOPPED_A_PORT=19113
readonly TIE_STOPPED_B_PORT=19114
readonly TIE_CANDIDATE_A_PORT=19121
readonly TIE_CANDIDATE_B_PORT=19122
readonly TIE_DECISION_PORT=19130
readonly TIE_LOSER_ACK_PORT=19140
readonly TIE_HEAL_PORT=19150
readonly TIE_FINISHED_PORT=19160
readonly TIE_FULL_NODE_PORT=8444

tie_error() {
  test_log ERROR scenario "$*"
}

tie_normalize_hash() {
  local hash="${1:-}"
  hash="${hash#0x}"
  printf '%s\n' "${hash,,}"
}

tie_barrier() {
  local port="${1:?barrier port missing}"
  local expected="${2:?barrier message missing}"
  local received
  if [[ "${NODE_NAME}" == node03 ]]; then
    action_signal_serve "${port}" 8 "${expected}" "${TIE_TIMEOUT}" >/dev/null
  else
    received="$(action_signal_wait node03 "${port}" "${TIE_TIMEOUT}")"
    if [[ "${received}" != "${expected}" ]]; then
      tie_error "unexpected barrier message: ${received}"
      return 1
    fi
  fi
}

tie_partition_full_nodes() {
  case "${NODE_NAME}" in
    node01)
      network_partition_port node02 "${TIE_FULL_NODE_PORT}"
      network_partition_port node03 "${TIE_FULL_NODE_PORT}"
      ;;
    node02)
      network_partition_port node01 "${TIE_FULL_NODE_PORT}"
      network_partition_port node03 "${TIE_FULL_NODE_PORT}"
      ;;
    node03)
      network_partition_port node01 "${TIE_FULL_NODE_PORT}"
      network_partition_port node02 "${TIE_FULL_NODE_PORT}"
      ;;
  esac
}

tie_prepare_race() {
  case "${NODE_NAME}" in
    node01|node02)
      action_start_farming
      action_wait_for_plot 180
      ;;
    node04|node07)
      action_start_timelord_server
      action_wait_for_vdf_server 180
      ;;
  esac
}

tie_release_vdf() {
  case "${NODE_NAME}" in
    node04|node07)
      action_start_timelord_vdf
      action_wait_for_vdf_clients 3 "${TIE_TIMEOUT}"
      ;;
    node05|node06|node08|node09)
      action_start_vdf
      ;;
  esac
}

tie_stop_timing_member() {
  local farmer="${1:?farmer host missing}"
  local stop_port="${2:?stop port missing}"
  local stopped_port="${3:?stopped port missing}"
  local label="${4:?cluster label missing}"
  local message

  message="$(action_signal_wait "${farmer}" "${stop_port}" "${TIE_TIMEOUT}")"
  if [[ "${message}" != "STOP_${label}" ]]; then
    tie_error "unexpected timing stop message: ${message}"
    return 1
  fi

  if [[ "${NODE_ROLE}" == timelord ]]; then
    action_stop_timelord
  else
    action_stop_vdf
  fi

  message="$(action_signal_wait "${farmer}" "${stopped_port}" "${TIE_TIMEOUT}")"
  if [[ "${message}" != "STOPPED_${label}" ]]; then
    tie_error "unexpected timing acknowledgement: ${message}"
    return 1
  fi
}

tie_candidate_message() {
  local parent_height="${1:?parent height missing}"
  local parent_hash="${2:?parent hash missing}"
  local started_ns="${3:?start time missing}"
  local captured_ns="${4:?capture time missing}"
  printf 'CANDIDATE|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${NODE_NAME}" \
    "${parent_height}" \
    "${parent_hash}" \
    "${ACTION_CANDIDATE_HEIGHT}" \
    "${ACTION_CANDIDATE_HASH}" \
    "${ACTION_CANDIDATE_PREV_HASH}" \
    "${ACTION_CANDIDATE_WEIGHT}" \
    "${ACTION_CANDIDATE_TOTAL_ITERS}" \
    "${started_ns}" \
    "${captured_ns}"
}

tie_build_decision() {
  local candidate_a="${1:?node01 candidate missing}"
  local candidate_b="${2:?node02 candidate missing}"
  local marker_a node_a parent_height_a parent_hash_a height_a hash_a prev_a weight_a iters_a start_a capture_a extra_a
  local marker_b node_b parent_height_b parent_hash_b height_b hash_b prev_b weight_b iters_b start_b capture_b extra_b
  local parent_a parent_b previous_a previous_b normalized_a normalized_b winner loser winner_hash loser_hash
  local winner_iters loser_iters difference gap_ms

  IFS='|' read -r marker_a node_a parent_height_a parent_hash_a height_a hash_a prev_a weight_a iters_a start_a capture_a extra_a <<<"${candidate_a}"
  IFS='|' read -r marker_b node_b parent_height_b parent_hash_b height_b hash_b prev_b weight_b iters_b start_b capture_b extra_b <<<"${candidate_b}"

  if [[ "${marker_a}" != CANDIDATE || "${marker_b}" != CANDIDATE || -n "${extra_a:-}" || -n "${extra_b:-}" ]]; then
    printf '%s\n' 'ABORT|invalid_candidate_format'
    return 0
  fi
  if [[ "${node_a}" != node01 || "${node_b}" != node02 ]]; then
    printf '%s\n' 'ABORT|unexpected_candidate_owner'
    return 0
  fi
  if [[ ! "${parent_height_a}" =~ ^[0-9]+$ || ! "${parent_height_b}" =~ ^[0-9]+$ \
        || ! "${height_a}" =~ ^[0-9]+$ || ! "${height_b}" =~ ^[0-9]+$ \
        || ! "${weight_a}" =~ ^[0-9]+$ || ! "${weight_b}" =~ ^[0-9]+$ \
        || ! "${iters_a}" =~ ^[0-9]+$ || ! "${iters_b}" =~ ^[0-9]+$ \
        || ! "${start_a}" =~ ^[0-9]+$ || ! "${start_b}" =~ ^[0-9]+$ \
        || ! "${capture_a}" =~ ^[0-9]+$ || ! "${capture_b}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'ABORT|non_numeric_candidate_field'
    return 0
  fi
  if [[ ! "${parent_hash_a}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${parent_hash_b}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${hash_a}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${hash_b}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${prev_a}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${prev_b}" =~ ^(0x)?[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' 'ABORT|invalid_candidate_hash'
    return 0
  fi

  parent_a="$(tie_normalize_hash "${parent_hash_a}")"
  parent_b="$(tie_normalize_hash "${parent_hash_b}")"
  previous_a="$(tie_normalize_hash "${prev_a}")"
  previous_b="$(tie_normalize_hash "${prev_b}")"
  normalized_a="$(tie_normalize_hash "${hash_a}")"
  normalized_b="$(tie_normalize_hash "${hash_b}")"

  if [[ "${parent_height_a}" != "${parent_height_b}" || "${parent_a}" != "${parent_b}" ]]; then
    printf '%s\n' 'ABORT|branches_did_not_start_from_same_peak'
    return 0
  fi
  if (( height_a != parent_height_a + 1 || height_b != parent_height_b + 1 )); then
    printf '%s\n' 'ABORT|branch_created_more_or_less_than_one_block'
    return 0
  fi
  if [[ "${previous_a}" != "${parent_a}" || "${previous_b}" != "${parent_b}" ]]; then
    printf '%s\n' 'ABORT|candidate_parent_mismatch'
    return 0
  fi
  if [[ "${normalized_a}" == "${normalized_b}" ]]; then
    printf '%s\n' 'ABORT|candidate_hashes_are_identical'
    return 0
  fi
  if [[ "${weight_a}" != "${weight_b}" ]]; then
    printf '%s\n' 'ABORT|candidate_weights_are_not_equal'
    return 0
  fi
  if [[ "${iters_a}" == "${iters_b}" ]]; then
    printf '%s\n' 'ABORT|candidate_total_iterations_are_equal'
    return 0
  fi

  if (( iters_a < iters_b )); then
    winner=node01
    winner_hash="${hash_a}"
    winner_iters="${iters_a}"
    loser=node02
    loser_hash="${hash_b}"
    loser_iters="${iters_b}"
  else
    winner=node02
    winner_hash="${hash_b}"
    winner_iters="${iters_b}"
    loser=node01
    loser_hash="${hash_a}"
    loser_iters="${iters_a}"
  fi

  if (( capture_a >= capture_b )); then
    difference=$((capture_a - capture_b))
  else
    difference=$((capture_b - capture_a))
  fi
  gap_ms=$((difference / 1000000))

  printf 'TIE|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${winner}" "${winner_hash}" "${winner_iters}" \
    "${loser}" "${loser_hash}" "${loser_iters}" \
    "${height_a}" "${weight_a}" "${parent_hash_a}" "${gap_ms}"
}

tie_parse_decision() {
  local decision="${1:?decision missing}"
  local marker extra
  IFS='|' read -r marker \
    TIE_WINNER TIE_WINNER_HASH TIE_WINNER_ITERS \
    TIE_LOSER TIE_LOSER_HASH TIE_LOSER_ITERS \
    TIE_HEIGHT TIE_WEIGHT TIE_PARENT_HASH TIE_CAPTURE_GAP_MS extra <<<"${decision}"
  if [[ "${marker}" != TIE || -n "${extra:-}" ]]; then
    tie_error "tie construction aborted: ${decision}"
    return 1
  fi
  export TIE_WINNER TIE_WINNER_HASH TIE_WINNER_ITERS
  export TIE_LOSER TIE_LOSER_HASH TIE_LOSER_ITERS
  export TIE_HEIGHT TIE_WEIGHT TIE_PARENT_HASH TIE_CAPTURE_GAP_MS
}

tie_converge_branch_pair() {
  local peer="${1:?peer branch node missing}"
  network_heal_port "${peer}" "${TIE_FULL_NODE_PORT}"
  action_connect_peer "${peer}" "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
  action_wait_for_peak_hash "${TIE_WINNER_HASH}" "${TIE_TIMEOUT}"
}

tie_restore_full_node_mesh() {
  network_reset
  case "${NODE_NAME}" in
    node01)
      action_connect_peer node02 "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
      action_connect_peer node03 "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
      ;;
    node02)
      action_connect_peer node01 "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
      action_connect_peer node03 "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
      ;;
    node03)
      action_connect_peer node01 "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
      action_connect_peer node02 "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
      ;;
  esac
}

tie_run_farmer_branch() {
  local peer="${1:?peer farmer missing}"
  local stop_port="${2:?stop port missing}"
  local stopped_port="${3:?stopped port missing}"
  local candidate_port="${4:?candidate port missing}"
  local label="${5:?cluster label missing}"
  local state parent_height parent_hash started_ns captured_ns candidate decision heal_message

  state="$(_action_blockchain_state)"
  parent_height="$(jq -er '.blockchain_state.peak.height' <<<"${state}")"
  parent_hash="$(jq -er '.blockchain_state.peak.header_hash' <<<"${state}")"
  started_ns="$(date +%s%N)"

  action_capture_next_block "${parent_height}" "${TIE_TIMEOUT}"
  captured_ns="$(date +%s%N)"
  action_signal_serve "${stop_port}" 3 "STOP_${label}" "${TIE_TIMEOUT}" >/dev/null
  action_signal_serve "${stopped_port}" 3 "STOPPED_${label}" "${TIE_TIMEOUT}" >/dev/null
  action_finish_frozen_block

  candidate="$(tie_candidate_message "${parent_height}" "${parent_hash}" "${started_ns}" "${captured_ns}")"
  action_signal_serve "${candidate_port}" 1 "${candidate}" "${TIE_TIMEOUT}" >/dev/null

  decision="$(action_signal_wait node03 "${TIE_DECISION_PORT}" "${TIE_TIMEOUT}")"
  tie_parse_decision "${decision}"
  tie_converge_branch_pair "${peer}"

  if [[ "${NODE_NAME}" == "${TIE_LOSER}" ]]; then
    action_signal_serve "${TIE_LOSER_ACK_PORT}" 1 \
      "CONVERGED|${NODE_NAME}|${TIE_WINNER_HASH}" "${TIE_TIMEOUT}" >/dev/null
  fi

  heal_message="$(action_signal_wait node03 "${TIE_HEAL_PORT}" "${TIE_TIMEOUT}")"
  if [[ "${heal_message}" != "HEAL|${TIE_WINNER_HASH}" ]]; then
    tie_error "unexpected mesh-heal message: ${heal_message}"
    return 1
  fi

  tie_restore_full_node_mesh
  action_wait_for_peak_hash "${TIE_WINNER_HASH}" "${TIE_TIMEOUT}"
  tie_barrier "${TIE_FINISHED_PORT}" "FINISHED|${TIE_WINNER_HASH}"
}

tie_run_coordinator() {
  local candidate_a candidate_b decision acknowledgement

  candidate_a="$(action_signal_wait node01 "${TIE_CANDIDATE_A_PORT}" "${TIE_TIMEOUT}")"
  candidate_b="$(action_signal_wait node02 "${TIE_CANDIDATE_B_PORT}" "${TIE_TIMEOUT}")"
  decision="$(tie_build_decision "${candidate_a}" "${candidate_b}")"
  action_signal_serve "${TIE_DECISION_PORT}" 8 "${decision}" "${TIE_TIMEOUT}" >/dev/null
  tie_parse_decision "${decision}"

  acknowledgement="$(action_signal_wait "${TIE_LOSER}" "${TIE_LOSER_ACK_PORT}" "${TIE_TIMEOUT}")"
  if [[ "${acknowledgement}" != "CONVERGED|${TIE_LOSER}|${TIE_WINNER_HASH}" ]]; then
    tie_error "unexpected loser acknowledgement: ${acknowledgement}"
    return 1
  fi

  action_signal_serve "${TIE_HEAL_PORT}" 8 "HEAL|${TIE_WINNER_HASH}" "${TIE_TIMEOUT}" >/dev/null
  tie_restore_full_node_mesh
  action_wait_for_peak_hash "${TIE_WINNER_HASH}" "${TIE_TIMEOUT}"
  tie_barrier "${TIE_FINISHED_PORT}" "FINISHED|${TIE_WINNER_HASH}"

  test_log INFO scenario \
    "TIE-BREAK COMPLETE: height=${TIE_HEIGHT} parent=${TIE_PARENT_HASH} equal_weight=${TIE_WEIGHT} winner=${TIE_WINNER} winner_total_iters=${TIE_WINNER_ITERS} loser=${TIE_LOSER} loser_total_iters=${TIE_LOSER_ITERS} capture_gap_ms=${TIE_CAPTURE_GAP_MS} peak_hash=${TIE_WINNER_HASH}"
}

tie_run_timing_node() {
  local farmer="${1:?farmer host missing}"
  local stop_port="${2:?stop port missing}"
  local stopped_port="${3:?stopped port missing}"
  local label="${4:?cluster label missing}"
  local decision heal_message

  tie_stop_timing_member "${farmer}" "${stop_port}" "${stopped_port}" "${label}"
  decision="$(action_signal_wait node03 "${TIE_DECISION_PORT}" "${TIE_TIMEOUT}")"
  tie_parse_decision "${decision}"
  heal_message="$(action_signal_wait node03 "${TIE_HEAL_PORT}" "${TIE_TIMEOUT}")"
  if [[ "${heal_message}" != "HEAL|${TIE_WINNER_HASH}" ]]; then
    tie_error "unexpected mesh-heal message: ${heal_message}"
    return 1
  fi
  tie_barrier "${TIE_FINISHED_PORT}" "FINISHED|${TIE_WINNER_HASH}"
}

tie_scenario_main() {
  tie_partition_full_nodes
  tie_barrier "${TIE_PARTITION_PORT}" PARTITIONED
  tie_prepare_race
  tie_barrier "${TIE_TIMING_READY_PORT}" START_RACE
  tie_release_vdf

  case "${NODE_NAME}" in
    node01)
      tie_run_farmer_branch node02 \
        "${TIE_STOP_A_PORT}" "${TIE_STOPPED_A_PORT}" "${TIE_CANDIDATE_A_PORT}" A
      ;;
    node02)
      tie_run_farmer_branch node01 \
        "${TIE_STOP_B_PORT}" "${TIE_STOPPED_B_PORT}" "${TIE_CANDIDATE_B_PORT}" B
      ;;
    node03)
      tie_run_coordinator
      ;;
    node04|node05|node06)
      tie_run_timing_node node01 "${TIE_STOP_A_PORT}" "${TIE_STOPPED_A_PORT}" A
      ;;
    node07|node08|node09)
      tie_run_timing_node node02 "${TIE_STOP_B_PORT}" "${TIE_STOPPED_B_PORT}" B
      ;;
    *)
      tie_error "unsupported node ${NODE_NAME}"
      return 1
      ;;
  esac
}
