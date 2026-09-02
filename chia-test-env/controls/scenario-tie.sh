#!/usr/bin/env bash
set -Eeuo pipefail

source /workspace/controls/actions.sh
source /workspace/controls/network.sh

readonly TIE_TIMEOUT="${TIE_TIMEOUT:-1200}"
readonly TIE_MAX_ATTEMPTS="${TIE_MAX_ATTEMPTS:-12}"
readonly TIE_MAX_CAPTURE_GAP_MS="${TIE_MAX_CAPTURE_GAP_MS:-1000}"
readonly TIE_ACTIVATION_HEIGHT="${TIE_ACTIVATION_HEIGHT:-200}"
readonly TIE_MAX_FARMERS=4
readonly TIE_COORDINATOR="${TIE_COORDINATOR:-node09}"
readonly TIE_VDF_CLIENTS_PER_TIMELORD="${VDF_CLIENTS_PER_TIMELORD:-3}"
readonly TIE_FULL_NODE_PORT=8444
readonly TIE_PARTITION_PORT=19101
readonly TIE_START_VDF_PORT=19102
readonly TIE_VDF_READY_PORT=19103
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
readonly TIE_COMPLETE_PORT=19170

IFS=',' read -r -a TIE_FARMERS <<<"${FARMER_NODES:-node01,node02,node03,node04}"
IFS=',' read -r -a TIE_TIMING_A <<<"${TIE_TIMING_A_NODES:-node06,node08}"
IFS=',' read -r -a TIE_TIMING_B <<<"${TIE_TIMING_B_NODES:-node07,node09}"
IFS=',' read -r -a TIE_SCENARIO_NODES <<<"${SCENARIO_NODES:-node01,node02,node03,node04,node06,node07,node08,node09}"
readonly -a TIE_FARMERS TIE_TIMING_A TIE_TIMING_B TIE_SCENARIO_NODES
TIE_OTHER_NODE_COUNT=0
TIE_LOCAL_PARENT_HEIGHT=''
TIE_LOCAL_PARENT_HASH=''
TIE_LOCAL_STARTED_NS=''

tie_error() {
  test_log ERROR scenario "$*"
}

tie_contains() {
  local expected="${1:?value missing}"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == "${expected}" ]] && return 0
  done
  return 1
}

tie_normalize_hash() {
  local hash="${1:-}"
  hash="${hash#0x}"
  printf '%s\n' "${hash,,}"
}

tie_validate_topology() {
  local expected_role member
  if (( ${#TIE_FARMERS[@]} < 2 || ${#TIE_FARMERS[@]} > TIE_MAX_FARMERS \
        || ${#TIE_TIMING_A[@]} < 2 || ${#TIE_TIMING_B[@]} < 2 )); then
    tie_error 'two to four farmers and at least two members in each timing group are required'
    return 1
  fi
  if [[ ! "${TIE_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ \
        || ! "${TIE_VDF_CLIENTS_PER_TIMELORD}" =~ ^([3-9]|[1-9][0-9]+)$ \
        || ! "${TIE_MAX_CAPTURE_GAP_MS}" =~ ^[0-9]+$ \
        || ! "${TIE_ACTIVATION_HEIGHT}" =~ ^[0-9]+$ ]]; then
    tie_error 'attempts must be positive, VDF clients at least three, and gap/activation values non-negative'
    return 1
  fi
  if (( ${#TIE_SCENARIO_NODES[@]} != ${#TIE_FARMERS[@]} + ${#TIE_TIMING_A[@]} + ${#TIE_TIMING_B[@]} )); then
    tie_error 'scenario node list does not match farmer and timing group membership'
    return 1
  fi
  if ! tie_contains "${TIE_COORDINATOR}" "${TIE_TIMING_B[@]}"; then
    tie_error "coordinator ${TIE_COORDINATOR} must be in timing group B"
    return 1
  fi
  if tie_contains "${NODE_NAME}" "${TIE_FARMERS[@]}"; then
    expected_role=farmer
  elif [[ "${NODE_NAME}" == "${TIE_TIMING_A[0]}" || "${NODE_NAME}" == "${TIE_TIMING_B[0]}" ]]; then
    expected_role=timelord
  elif tie_contains "${NODE_NAME}" "${TIE_TIMING_A[@]:1}" \
      || tie_contains "${NODE_NAME}" "${TIE_TIMING_B[@]:1}"; then
    expected_role=vdf
  else
    tie_error "${NODE_NAME} has no scenario role"
    return 1
  fi
  if [[ "${NODE_ROLE}" != "${expected_role}" ]]; then
    tie_error "${NODE_NAME} has role ${NODE_ROLE}; expected ${expected_role}"
    return 1
  fi
  for member in "${TIE_FARMERS[@]}" "${TIE_TIMING_A[@]}" "${TIE_TIMING_B[@]}"; do
    tie_contains "${member}" "${TIE_SCENARIO_NODES[@]}" || {
      tie_error "${member} is missing from SCENARIO_NODES"
      return 1
    }
  done
  TIE_OTHER_NODE_COUNT=$((${#TIE_SCENARIO_NODES[@]} - 1))
}

tie_barrier() {
  local port="${1:?barrier port missing}"
  local expected="${2:?barrier message missing}"
  local received
  if [[ "${NODE_NAME}" == "${TIE_COORDINATOR}" ]]; then
    action_signal_serve "${port}" "${TIE_OTHER_NODE_COUNT}" "${expected}" "${TIE_TIMEOUT}" >/dev/null
  else
    received="$(action_signal_wait "${TIE_COORDINATOR}" "${port}" "${TIE_TIMEOUT}")"
    if [[ "${received}" != "${expected}" ]]; then
      tie_error "unexpected barrier message: ${received}"
      return 1
    fi
  fi
}

tie_partition_attempt() {
  local farmer_a="${1:?farmer A missing}"
  local farmer_b="${2:?farmer B missing}"
  local peer
  network_reset
  if tie_contains "${NODE_NAME}" "${TIE_FARMERS[@]}"; then
    for peer in "${TIE_FARMERS[@]}"; do
      [[ "${peer}" == "${NODE_NAME}" ]] || network_partition_port "${peer}" "${TIE_FULL_NODE_PORT}"
    done
    if [[ "${NODE_NAME}" == "${farmer_a}" ]]; then
      network_partition_port "${TIE_TIMING_B[0]}" "${TIE_FULL_NODE_PORT}"
    elif [[ "${NODE_NAME}" == "${farmer_b}" ]]; then
      network_partition_port "${TIE_TIMING_A[0]}" "${TIE_FULL_NODE_PORT}"
    else
      network_partition_port "${TIE_TIMING_A[0]}" "${TIE_FULL_NODE_PORT}"
      network_partition_port "${TIE_TIMING_B[0]}" "${TIE_FULL_NODE_PORT}"
    fi
  elif [[ "${NODE_NAME}" == "${TIE_TIMING_A[0]}" ]]; then
    for peer in "${TIE_FARMERS[@]}"; do
      [[ "${peer}" == "${farmer_a}" ]] || network_partition_port "${peer}" "${TIE_FULL_NODE_PORT}"
    done
  elif [[ "${NODE_NAME}" == "${TIE_TIMING_B[0]}" ]]; then
    for peer in "${TIE_FARMERS[@]}"; do
      [[ "${peer}" == "${farmer_b}" ]] || network_partition_port "${peer}" "${TIE_FULL_NODE_PORT}"
    done
  fi
}

tie_prepare_attempt() {
  local farmer_a="${1:?farmer A missing}"
  local farmer_b="${2:?farmer B missing}"
  local state
  if [[ "${NODE_NAME}" == "${farmer_a}" || "${NODE_NAME}" == "${farmer_b}" ]]; then
    action_start_farming
    action_wait_for_plot 180
    state="$(_action_blockchain_state)"
    TIE_LOCAL_PARENT_HEIGHT="$(jq -er '.blockchain_state.peak.height' <<<"${state}")"
    TIE_LOCAL_PARENT_HASH="$(jq -er '.blockchain_state.peak.header_hash' <<<"${state}")"
    TIE_LOCAL_STARTED_NS="$(date +%s%N)"
  elif [[ "${NODE_NAME}" == "${TIE_TIMING_A[0]}" || "${NODE_NAME}" == "${TIE_TIMING_B[0]}" ]]; then
    action_start_timelord_server
    action_wait_for_vdf_server 180
  fi
}

tie_release_vdf() {
  if [[ "${NODE_NAME}" == "${TIE_TIMING_A[0]}" ]]; then
    action_start_timelord_vdf
    action_wait_for_vdf_clients "${TIE_VDF_CLIENTS_PER_TIMELORD}" "${TIE_TIMEOUT}"
  elif [[ "${NODE_NAME}" == "${TIE_TIMING_B[0]}" ]]; then
    action_start_timelord_vdf
    action_wait_for_vdf_clients "${TIE_VDF_CLIENTS_PER_TIMELORD}" "${TIE_TIMEOUT}"
  elif tie_contains "${NODE_NAME}" "${TIE_TIMING_A[@]:1}" \
      || tie_contains "${NODE_NAME}" "${TIE_TIMING_B[@]:1}"; then
    action_start_vdf
  fi
}

tie_stop_timing_member() {
  local farmer="${1:?farmer host missing}"
  local stop_port="${2:?stop port missing}"
  local stopped_port="${3:?stopped port missing}"
  local round="${4:?round missing}"
  local attempt="${5:?attempt missing}"
  local label="${6:?cluster label missing}"
  local message expected_stop expected_stopped
  expected_stop="STOP|${round}|${attempt}|${label}"
  expected_stopped="STOPPED|${round}|${attempt}|${label}"
  message="$(action_signal_wait "${farmer}" "${stop_port}" "${TIE_TIMEOUT}")"
  if [[ "${message}" != "${expected_stop}" ]]; then
    tie_error "unexpected timing stop message: ${message}"
    return 1
  fi
  if [[ "${NODE_ROLE}" == timelord ]]; then
    action_stop_timelord
  else
    action_stop_vdf
  fi
  message="$(action_signal_wait "${farmer}" "${stopped_port}" "${TIE_TIMEOUT}")"
  if [[ "${message}" != "${expected_stopped}" ]]; then
    tie_error "unexpected timing acknowledgement: ${message}"
    return 1
  fi
}

tie_candidate_message() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local captured_ns="${3:?capture time missing}"
  local tie_key="${4:?tie key missing}"
  printf 'CANDIDATE|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${round}" "${attempt}" "${NODE_NAME}" \
    "${TIE_LOCAL_PARENT_HEIGHT}" "${TIE_LOCAL_PARENT_HASH}" \
    "${ACTION_CANDIDATE_HEIGHT}" "${ACTION_CANDIDATE_HASH}" \
    "${ACTION_CANDIDATE_PREV_HASH}" "${ACTION_CANDIDATE_WEIGHT}" \
    "${ACTION_CANDIDATE_TOTAL_ITERS}" "${tie_key}" \
    "${TIE_LOCAL_STARTED_NS}" "${captured_ns}"
}

tie_build_decision() {
  local expected_round="${1:?round missing}"
  local expected_attempt="${2:?attempt missing}"
  local expected_a="${3:?farmer A missing}"
  local expected_b="${4:?farmer B missing}"
  local candidate_a="${5:?candidate A missing}"
  local candidate_b="${6:?candidate B missing}"
  local marker_a round_a attempt_a node_a parent_height_a parent_hash_a height_a hash_a prev_a weight_a iters_a key_a start_a capture_a extra_a
  local marker_b round_b attempt_b node_b parent_height_b parent_hash_b height_b hash_b prev_b weight_b iters_b key_b start_b capture_b extra_b
  local parent_a parent_b previous_a previous_b normalized_a normalized_b
  local winner winner_hash winner_iters winner_key winner_height winner_weight
  local loser loser_hash loser_iters loser_key difference gap_ms max_gap_ns outcome reason
  local single_child=1
  IFS='|' read -r marker_a round_a attempt_a node_a parent_height_a parent_hash_a \
    height_a hash_a prev_a weight_a iters_a key_a start_a capture_a extra_a <<<"${candidate_a}"
  IFS='|' read -r marker_b round_b attempt_b node_b parent_height_b parent_hash_b \
    height_b hash_b prev_b weight_b iters_b key_b start_b capture_b extra_b <<<"${candidate_b}"
  if [[ "${marker_a}" != CANDIDATE || "${marker_b}" != CANDIDATE \
        || -n "${extra_a:-}" || -n "${extra_b:-}" ]]; then
    printf '%s\n' 'ABORT|invalid_candidate_format'; return 0
  fi
  if [[ "${round_a}" != "${expected_round}" || "${round_b}" != "${expected_round}" \
        || "${attempt_a}" != "${expected_attempt}" || "${attempt_b}" != "${expected_attempt}" ]]; then
    printf '%s\n' 'ABORT|candidate_round_or_attempt_mismatch'; return 0
  fi
  if [[ "${node_a}" != "${expected_a}" || "${node_b}" != "${expected_b}" ]]; then
    printf '%s\n' 'ABORT|unexpected_candidate_owner'; return 0
  fi
  if [[ ! "${parent_height_a}" =~ ^[0-9]+$ || ! "${parent_height_b}" =~ ^[0-9]+$ \
        || ! "${height_a}" =~ ^[0-9]+$ || ! "${height_b}" =~ ^[0-9]+$ \
        || ! "${weight_a}" =~ ^[0-9]+$ || ! "${weight_b}" =~ ^[0-9]+$ \
        || ! "${iters_a}" =~ ^[0-9]+$ || ! "${iters_b}" =~ ^[0-9]+$ \
        || ! "${start_a}" =~ ^[0-9]+$ || ! "${start_b}" =~ ^[0-9]+$ \
        || ! "${capture_a}" =~ ^[0-9]+$ || ! "${capture_b}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'ABORT|non_numeric_candidate_field'; return 0
  fi
  if [[ ! "${parent_hash_a}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${parent_hash_b}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${hash_a}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${hash_b}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${prev_a}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${prev_b}" =~ ^(0x)?[0-9a-fA-F]{64}$ \
        || ! "${key_a}" =~ ^[0-9a-f]{64}$ || ! "${key_b}" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' 'ABORT|invalid_candidate_hash_or_tie_key'; return 0
  fi
  parent_a="$(tie_normalize_hash "${parent_hash_a}")"
  parent_b="$(tie_normalize_hash "${parent_hash_b}")"
  previous_a="$(tie_normalize_hash "${prev_a}")"
  previous_b="$(tie_normalize_hash "${prev_b}")"
  normalized_a="$(tie_normalize_hash "${hash_a}")"
  normalized_b="$(tie_normalize_hash "${hash_b}")"
  if [[ "${parent_height_a}" != "${parent_height_b}" || "${parent_a}" != "${parent_b}" ]]; then
    printf '%s\n' 'ABORT|branches_did_not_start_from_same_peak'; return 0
  fi
  if (( height_a <= parent_height_a || height_b <= parent_height_b )); then
    printf '%s\n' 'ABORT|candidate_did_not_advance_parent'; return 0
  fi
  if (( height_a < TIE_ACTIVATION_HEIGHT || height_b < TIE_ACTIVATION_HEIGHT )); then
    printf '%s\n' 'ABORT|candidate_precedes_tie_break_activation'; return 0
  fi
  if (( height_a == parent_height_a + 1 )) && [[ "${previous_a}" != "${parent_a}" ]]; then
    printf '%s\n' 'ABORT|candidate_parent_mismatch'; return 0
  fi
  if (( height_b == parent_height_b + 1 )) && [[ "${previous_b}" != "${parent_b}" ]]; then
    printf '%s\n' 'ABORT|candidate_parent_mismatch'; return 0
  fi
  if (( height_a != parent_height_a + 1 || height_b != parent_height_b + 1 )); then
    single_child=0
  fi
  if [[ "${normalized_a}" == "${normalized_b}" ]]; then
    printf '%s\n' 'ABORT|candidate_hashes_are_identical'; return 0
  fi
  if (( capture_a >= capture_b )); then difference=$((capture_a - capture_b)); else difference=$((capture_b - capture_a)); fi
  # Round up so a value logged at the configured limit was actually accepted.
  gap_ms=$(((difference + 999999) / 1000000))
  max_gap_ns=$((TIE_MAX_CAPTURE_GAP_MS * 1000000))
  if (( weight_a > weight_b )); then
    winner="${node_a}"; winner_hash="${hash_a}"; winner_iters="${iters_a}"; winner_key="${key_a}"
    winner_height="${height_a}"; winner_weight="${weight_a}"
    loser="${node_b}"; loser_hash="${hash_b}"; loser_iters="${iters_b}"; loser_key="${key_b}"
    outcome=RETRY; reason=higher_weight
  elif (( weight_b > weight_a )); then
    winner="${node_b}"; winner_hash="${hash_b}"; winner_iters="${iters_b}"; winner_key="${key_b}"
    winner_height="${height_b}"; winner_weight="${weight_b}"
    loser="${node_a}"; loser_hash="${hash_a}"; loser_iters="${iters_a}"; loser_key="${key_a}"
    outcome=RETRY; reason=higher_weight
  elif [[ "${iters_a}" == "${iters_b}" ]]; then
    if [[ "${key_a}" < "${key_b}" || ( "${key_a}" == "${key_b}" && "${normalized_a}" < "${normalized_b}" ) ]]; then
      winner="${node_a}"; winner_hash="${hash_a}"; winner_iters="${iters_a}"; winner_key="${key_a}"
      winner_height="${height_a}"; winner_weight="${weight_a}"
      loser="${node_b}"; loser_hash="${hash_b}"; loser_iters="${iters_b}"; loser_key="${key_b}"
    else
      winner="${node_b}"; winner_hash="${hash_b}"; winner_iters="${iters_b}"; winner_key="${key_b}"
      winner_height="${height_b}"; winner_weight="${weight_b}"
      loser="${node_a}"; loser_hash="${hash_a}"; loser_iters="${iters_a}"; loser_key="${key_a}"
    fi
    [[ "${key_a}" == "${key_b}" ]] && reason=header_hash_fallback || reason=tie_break_key
    if (( single_child == 0 )); then
      outcome=RETRY; reason="multiple_blocks_${reason}"
    elif (( difference > max_gap_ns )); then
      outcome=RETRY; reason="capture_gap_${reason}"
    else
      outcome=EXACT
    fi
  elif (( iters_a < iters_b )); then
    winner="${node_a}"; winner_hash="${hash_a}"; winner_iters="${iters_a}"; winner_key="${key_a}"
    winner_height="${height_a}"; winner_weight="${weight_a}"
    loser="${node_b}"; loser_hash="${hash_b}"; loser_iters="${iters_b}"; loser_key="${key_b}"
    outcome=RETRY; reason=lower_total_iters
  else
    winner="${node_b}"; winner_hash="${hash_b}"; winner_iters="${iters_b}"; winner_key="${key_b}"
    winner_height="${height_b}"; winner_weight="${weight_b}"
    loser="${node_a}"; loser_hash="${hash_a}"; loser_iters="${iters_a}"; loser_key="${key_a}"
    outcome=RETRY; reason=lower_total_iters
  fi
  printf 'DECISION|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${expected_round}" "${expected_attempt}" "${outcome}" "${reason}" \
    "${winner}" "${winner_hash}" "${winner_iters}" "${winner_key}" \
    "${loser}" "${loser_hash}" "${loser_iters}" "${loser_key}" \
    "${winner_height}" "${winner_weight}" "${parent_hash_a}" "${gap_ms}"
}

tie_parse_decision() {
  local decision="${1:?decision missing}"
  local expected_round="${2:?round missing}"
  local expected_attempt="${3:?attempt missing}"
  local marker round attempt extra
  IFS='|' read -r marker round attempt TIE_OUTCOME TIE_REASON \
    TIE_WINNER TIE_WINNER_HASH TIE_WINNER_ITERS TIE_WINNER_KEY \
    TIE_LOSER TIE_LOSER_HASH TIE_LOSER_ITERS TIE_LOSER_KEY \
    TIE_HEIGHT TIE_WEIGHT TIE_PARENT_HASH TIE_CAPTURE_GAP_MS extra <<<"${decision}"
  if [[ "${marker}" != DECISION || "${round}" != "${expected_round}" \
        || "${attempt}" != "${expected_attempt}" || -n "${extra:-}" ]]; then
    tie_error "tie construction aborted: ${decision}"; return 1
  fi
  if [[ "${TIE_OUTCOME}" != EXACT && "${TIE_OUTCOME}" != RETRY ]]; then
    tie_error "unsupported tie outcome: ${TIE_OUTCOME}"; return 1
  fi
  export TIE_OUTCOME TIE_REASON TIE_WINNER TIE_WINNER_HASH TIE_WINNER_ITERS TIE_WINNER_KEY
  export TIE_LOSER TIE_LOSER_HASH TIE_LOSER_ITERS TIE_LOSER_KEY
  export TIE_HEIGHT TIE_WEIGHT TIE_PARENT_HASH TIE_CAPTURE_GAP_MS
}

tie_wait_for_decision() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local decision
  decision="$(action_signal_wait "${TIE_COORDINATOR}" "${TIE_DECISION_PORT}" "${TIE_TIMEOUT}")"
  tie_parse_decision "${decision}" "${round}" "${attempt}"
}

tie_run_farmer_candidate() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local label="${3:?cluster label missing}"
  local stop_port stopped_port candidate_port timing_count captured_ns tie_key candidate
  if [[ "${label}" == A ]]; then
    stop_port="${TIE_STOP_A_PORT}"; stopped_port="${TIE_STOPPED_A_PORT}"
    candidate_port="${TIE_CANDIDATE_A_PORT}"; timing_count="${#TIE_TIMING_A[@]}"
  else
    stop_port="${TIE_STOP_B_PORT}"; stopped_port="${TIE_STOPPED_B_PORT}"
    candidate_port="${TIE_CANDIDATE_B_PORT}"; timing_count="${#TIE_TIMING_B[@]}"
  fi
  action_capture_next_block "${TIE_LOCAL_PARENT_HEIGHT}" "${TIE_TIMEOUT}"
  captured_ns="$(date +%s%N)"
  action_signal_serve "${stop_port}" "${timing_count}" \
    "STOP|${round}|${attempt}|${label}" "${TIE_TIMEOUT}" >/dev/null
  action_signal_serve "${stopped_port}" "${timing_count}" \
    "STOPPED|${round}|${attempt}|${label}" "${TIE_TIMEOUT}" >/dev/null
  action_finish_frozen_block
  tie_key="$(action_fork_tie_key "${ACTION_CANDIDATE_HASH}")"
  candidate="$(tie_candidate_message "${round}" "${attempt}" "${captured_ns}" "${tie_key}")"
  action_signal_serve "${candidate_port}" 1 "${candidate}" "${TIE_TIMEOUT}" >/dev/null
  tie_wait_for_decision "${round}" "${attempt}"
}

tie_coordinate_attempt() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local farmer_a="${3:?farmer A missing}"
  local farmer_b="${4:?farmer B missing}"
  local candidate_a candidate_b decision
  candidate_a="$(action_signal_wait "${farmer_a}" "${TIE_CANDIDATE_A_PORT}" "${TIE_TIMEOUT}")"
  candidate_b="$(action_signal_wait "${farmer_b}" "${TIE_CANDIDATE_B_PORT}" "${TIE_TIMEOUT}")"
  decision="$(tie_build_decision "${round}" "${attempt}" "${farmer_a}" "${farmer_b}" "${candidate_a}" "${candidate_b}")"
  action_signal_serve "${TIE_DECISION_PORT}" "${TIE_OTHER_NODE_COUNT}" \
    "${decision}" "${TIE_TIMEOUT}" >/dev/null
  tie_parse_decision "${decision}" "${round}" "${attempt}"
  test_log INFO scenario \
    "TIE ATTEMPT: round=${round} attempt=${attempt} pair=${farmer_a},${farmer_b} outcome=${TIE_OUTCOME} reason=${TIE_REASON} selected_height=${TIE_HEIGHT} selected_weight=${TIE_WEIGHT} winner=${TIE_WINNER} winner_total_iters=${TIE_WINNER_ITERS} winner_tie_key=${TIE_WINNER_KEY} loser=${TIE_LOSER} loser_total_iters=${TIE_LOSER_ITERS} loser_tie_key=${TIE_LOSER_KEY} capture_gap_ms=${TIE_CAPTURE_GAP_MS}"
}

tie_run_timing_node() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local farmer_a="${3:?farmer A missing}"
  local farmer_b="${4:?farmer B missing}"
  if tie_contains "${NODE_NAME}" "${TIE_TIMING_A[@]}"; then
    tie_stop_timing_member "${farmer_a}" "${TIE_STOP_A_PORT}" "${TIE_STOPPED_A_PORT}" "${round}" "${attempt}" A
  else
    tie_stop_timing_member "${farmer_b}" "${TIE_STOP_B_PORT}" "${TIE_STOPPED_B_PORT}" "${round}" "${attempt}" B
  fi
  if [[ "${NODE_NAME}" == "${TIE_COORDINATOR}" ]]; then
    tie_coordinate_attempt "${round}" "${attempt}" "${farmer_a}" "${farmer_b}"
  else
    tie_wait_for_decision "${round}" "${attempt}"
  fi
}

tie_converge_pair() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local farmer_a="${3:?farmer A missing}"
  local farmer_b="${4:?farmer B missing}"
  local peer acknowledgement
  if [[ "${NODE_NAME}" == "${farmer_a}" ]]; then peer="${farmer_b}"
  elif [[ "${NODE_NAME}" == "${farmer_b}" ]]; then peer="${farmer_a}"
  else return 0
  fi
  network_heal_port "${peer}" "${TIE_FULL_NODE_PORT}"
  action_connect_peer "${peer}" "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
  action_wait_for_peak_hash "${TIE_WINNER_HASH}" "${TIE_TIMEOUT}"
  if [[ "${NODE_NAME}" == "${TIE_LOSER}" ]]; then
    acknowledgement="CONVERGED|${round}|${attempt}|${NODE_NAME}|${TIE_WINNER_HASH}"
    action_signal_serve "${TIE_LOSER_ACK_PORT}" 1 "${acknowledgement}" "${TIE_TIMEOUT}" >/dev/null
  fi
}

tie_release_mesh_heal() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local acknowledgement expected heal_message
  expected="CONVERGED|${round}|${attempt}|${TIE_LOSER}|${TIE_WINNER_HASH}"
  heal_message="HEAL|${round}|${attempt}|${TIE_WINNER_HASH}"
  if [[ "${NODE_NAME}" == "${TIE_COORDINATOR}" ]]; then
    acknowledgement="$(action_signal_wait "${TIE_LOSER}" "${TIE_LOSER_ACK_PORT}" "${TIE_TIMEOUT}")"
    if [[ "${acknowledgement}" != "${expected}" ]]; then tie_error "unexpected loser acknowledgement: ${acknowledgement}"; return 1; fi
    action_signal_serve "${TIE_HEAL_PORT}" "${TIE_OTHER_NODE_COUNT}" \
      "${heal_message}" "${TIE_TIMEOUT}" >/dev/null
  else
    acknowledgement="$(action_signal_wait "${TIE_COORDINATOR}" "${TIE_HEAL_PORT}" "${TIE_TIMEOUT}")"
    if [[ "${acknowledgement}" != "${heal_message}" ]]; then tie_error "unexpected mesh-heal message: ${acknowledgement}"; return 1; fi
  fi
}

tie_restore_full_node_mesh() {
  local peer
  network_reset
  if tie_contains "${NODE_NAME}" "${TIE_FARMERS[@]}"; then
    for peer in "${TIE_FARMERS[@]}"; do
      [[ "${peer}" == "${NODE_NAME}" ]] && continue
      action_connect_peer "${peer}" "${TIE_FULL_NODE_PORT}" >/dev/null 2>&1 || true
    done
    action_wait_for_peak_hash "${TIE_WINNER_HASH}" "${TIE_TIMEOUT}"
  fi
}

tie_run_attempt() {
  local round="${1:?round missing}"
  local attempt="${2:?attempt missing}"
  local farmer_a="${3:?farmer A missing}"
  local farmer_b="${4:?farmer B missing}"
  local marker="R${round}A${attempt}"
  tie_partition_attempt "${farmer_a}" "${farmer_b}"
  tie_barrier "${TIE_PARTITION_PORT}" "PARTITIONED|${marker}|${farmer_a}|${farmer_b}"
  tie_prepare_attempt "${farmer_a}" "${farmer_b}"
  tie_barrier "${TIE_START_VDF_PORT}" "START_VDF|${marker}"
  tie_release_vdf
  tie_barrier "${TIE_VDF_READY_PORT}" "VDF_READY|${marker}"
  if [[ "${NODE_NAME}" == "${farmer_a}" ]]; then
    tie_run_farmer_candidate "${round}" "${attempt}" A
  elif [[ "${NODE_NAME}" == "${farmer_b}" ]]; then
    tie_run_farmer_candidate "${round}" "${attempt}" B
  elif tie_contains "${NODE_NAME}" "${TIE_TIMING_A[@]}" \
      || tie_contains "${NODE_NAME}" "${TIE_TIMING_B[@]}"; then
    tie_run_timing_node "${round}" "${attempt}" "${farmer_a}" "${farmer_b}"
  else
    tie_wait_for_decision "${round}" "${attempt}"
  fi
  tie_converge_pair "${round}" "${attempt}" "${farmer_a}" "${farmer_b}"
  tie_release_mesh_heal "${round}" "${attempt}"
  tie_restore_full_node_mesh
  tie_barrier "${TIE_FINISHED_PORT}" "FINISHED|${marker}|${TIE_WINNER_HASH}"
}

tie_scenario_main() {
  local round attempt farmer_a farmer_b exact_found
  tie_validate_topology
  for ((round = 1; round <= ${#TIE_FARMERS[@]}; round++)); do
    farmer_a="${TIE_FARMERS[round - 1]}"
    farmer_b="${TIE_FARMERS[round % ${#TIE_FARMERS[@]}]}"
    exact_found=0
    for ((attempt = 1; attempt <= TIE_MAX_ATTEMPTS; attempt++)); do
      tie_run_attempt "${round}" "${attempt}" "${farmer_a}" "${farmer_b}"
      if [[ "${TIE_OUTCOME}" == EXACT ]]; then
        exact_found=1
        if [[ "${NODE_NAME}" == "${TIE_COORDINATOR}" ]]; then
          test_log INFO scenario \
            "EXACT TIE COMPLETE: round=${round} pair=${farmer_a},${farmer_b} attempts=${attempt} height=${TIE_HEIGHT} total_iters=${TIE_WINNER_ITERS} capture_gap_ms=${TIE_CAPTURE_GAP_MS} selected_node=${TIE_WINNER} selected_hash=${TIE_WINNER_HASH} selected_tie_key=${TIE_WINNER_KEY} rejected_node=${TIE_LOSER} rejected_tie_key=${TIE_LOSER_KEY}"
        fi
        break
      fi
    done
    if (( exact_found == 0 )); then
      tie_error "no exact tie for ${farmer_a}/${farmer_b} after ${TIE_MAX_ATTEMPTS} attempts"
      return 1
    fi
  done
  tie_barrier "${TIE_COMPLETE_PORT}" "SCENARIO_COMPLETE|${#TIE_FARMERS[@]}"
}
