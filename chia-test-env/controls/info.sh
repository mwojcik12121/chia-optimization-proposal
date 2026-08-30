#!/usr/bin/env bash

_info_rpc() {
  local service="${1:?service missing}"
  local endpoint="${2:?endpoint missing}"
  local request="${3:-{}}"
  chia rpc "${service}" "${endpoint}" "${request}"
}

info_blockchain_state() {
  _info_rpc full_node get_blockchain_state '{}'
}

info_peak_height() {
  _info_rpc full_node get_blockchain_state '{}' \
    | jq -r '.blockchain_state.peak.height // -1'
}

info_peak_hash() {
  _info_rpc full_node get_blockchain_state '{}' \
    | jq -r '.blockchain_state.peak.header_hash // empty'
}

info_block_count() {
  local height
  height="$(info_peak_height)"
  printf '%s\n' "$((height + 1))"
}

info_last_block() {
  local hash
  hash="$(info_peak_hash)"
  _info_rpc full_node get_block_record \
    "$(jq -cn --arg header_hash "${hash}" '{header_hash:$header_hash}')"
}

info_block_at_height() {
  local height="${1:?height missing}"
  _info_rpc full_node get_block_record_by_height \
    "$(jq -cn --argjson height "${height}" '{height:$height}')"
}

info_connections() {
  _info_rpc full_node get_connections '{}'
}

info_mempool() {
  _info_rpc full_node get_all_mempool_items '{}'
}

info_consensus_state() {
  _info_rpc full_node get_blockchain_state '{}' \
    | jq '.blockchain_state | {difficulty,sub_slot_iters,space}'
}

info_wallet_sync() {
  _info_rpc wallet get_sync_status '{}'
}

info_wallet_balance() {
  local wallet_id="${1:-1}"
  _info_rpc wallet get_wallet_balance \
    "$(jq -cn --argjson wallet_id "${wallet_id}" '{wallet_id:$wallet_id}')"
}

info_farmer_signage_points() {
  _info_rpc farmer get_signage_points '{}'
}

info_harvesters() {
  _info_rpc farmer get_harvesters '{}'
}

info_plots() {
  _info_rpc harvester get_plots '{}'
}

info_timelord_state() {
  _info_rpc timelord get_connections '{}'
}

info_vdf_clients() {
  ss -Htn state established 2>/dev/null \
    | awk '$3 ~ /:8000$/ {count++} END {print count + 0}'
}

info_processes() {
  ps -eo pid,ppid,stat,etimes,comm,args \
    | awk 'NR == 1 || /chia_|chia |vdf_client|sia-signal/'
}

info_resources() {
  cat /sys/fs/cgroup/cpu.max 2>/dev/null || true
  cat /sys/fs/cgroup/memory.max 2>/dev/null || true
  cat /sys/fs/cgroup/memory.current 2>/dev/null || true
  df -h / /run/chia 2>/dev/null || true
}
