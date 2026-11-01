#!/usr/bin/env bash
set -Eeuo pipefail

helper="${LOCK_HELPER:-chia-lock-helper}"
if [[ "${1:-}" == --help || $# == 0 ]]; then
  printf 'Usage: lock-traffic.sh make-fixtures --output FILE --attack-count N --donor-blocks N | send-set --initial-burst-size N --burst-size N --burst-interval-seconds N --final-burst-size N --final-burst-lead-ms N ...\n'
  exit 0
fi

command="${1}"
shift
if [[ "${command}" == send-set ]]; then
  exec "${helper}" send-set "$@"
fi
[[ "${command}" == make-fixtures ]] || {
  printf 'unknown traffic command\n' >&2
  exit 64
}

output=''
attack_count=''
donor_blocks=''
while (( $# > 0 )); do
  case "$1" in
    --output) output="${2:?output value missing}" ;;
    --attack-count) attack_count="${2:?attack-count value missing}" ;;
    --donor-blocks) donor_blocks="${2:?donor-blocks value missing}" ;;
    *) printf 'unknown make-fixtures option: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift 2
done

[[ -n "${output}" && "${attack_count}" =~ ^[1-9][0-9]*$ \
   && "${donor_blocks}" =~ ^[1-9][0-9]*$ ]] || {
  printf 'invalid make-fixtures arguments\n' >&2
  exit 64
}

# Use the application CLI only for RPC. Serialization, hashing and TLS stay in
# the C++ helper, so every tested build receives the same serialized bytes.
state="$(chia rpc full_node get_blockchain_state '{}')"
height="$(jq -er '.blockchain_state.peak.height' <<<"${state}")"
context="$(jq -er '.blockchain_state.peak.header_hash' <<<"${state}")"
[[ "${height}" =~ ^[0-9]+$ ]] || exit 1

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT
: >"${temporary}/blocks.jsonl"
found=0
base_height=''
for ((h=height; h>=0 && found<donor_blocks; --h)); do
  record="$(chia rpc full_node get_block_record_by_height "$(jq -cn --argjson h "${h}" '{height:$h}')")"
  hash="$(jq -er '.block_record.header_hash' <<<"${record}")"
  chia rpc full_node get_block "$(jq -cn --arg hash "${hash}" '{header_hash:$hash}')" >"${temporary}/block.json"
  if jq -e '.block | .reward_chain_block.signage_point_index > 0 and
      .reward_chain_block.challenge_chain_sp_vdf != null and
      .reward_chain_block.reward_chain_sp_vdf != null and
      .challenge_chain_sp_proof != null and .reward_chain_sp_proof != null' \
      "${temporary}/block.json" >/dev/null; then
    jq -c '.block' "${temporary}/block.json" >>"${temporary}/blocks.jsonl"
    [[ -n "${base_height}" ]] || base_height="${h}"
    found=$((found + 1))
  fi
done

(( found >= donor_blocks )) || {
  printf 'lock-traffic: required %s recent nonzero signage-point blocks, found %s\n' \
    "${donor_blocks}" "${found}" >&2
  exit 1
}

jq -s '{blocks:.}' "${temporary}/blocks.jsonl" >"${temporary}/blocks.json"
"${helper}" make-fixtures \
  --blocks "${temporary}/blocks.json" \
  --base-height "${base_height}" \
  --context-hash "${context}" \
  --attack-count "${attack_count}" \
  --output "${output}"
