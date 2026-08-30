#!/usr/bin/env bash
set -Eeuo pipefail

export CHIA_ROOT=/opt/sia/plot-root
export CHIA_KEYS_ROOT=/opt/sia/plot-keys
readonly FINAL_DIR=/opt/sia/plot-output
readonly TEMP_DIR=/opt/sia/plot-temp
readonly MNEMONIC_FILE=/opt/sia/lab-mnemonic.txt

create_plots() {
  local index node
  local -a plots=()

  rm -rf "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" "${FINAL_DIR}" "${TEMP_DIR}" /opt/sia/plots
  mkdir -p "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" "${FINAL_DIR}" "${TEMP_DIR}" /opt/sia/plots

  chia init >/dev/null
  chia keys add --filename "${MNEMONIC_FILE}" --label private200 >/dev/null
  chia init --fix-ssl-permissions >/dev/null
  chia plots create \
    --size 18 \
    --override-k \
    --num 3 \
    --buffer 256 \
    --num_threads 2 \
    --buckets 64 \
    --tmp_dir "${TEMP_DIR}" \
    --final_dir "${FINAL_DIR}" \
    --exclude_final_dir

  mapfile -d '' -t plots < <(find "${FINAL_DIR}" -maxdepth 1 -type f -name '*.plot' -print0 | sort -z)
  (( ${#plots[@]} == 3 )) || {
    printf '[plot-assets][ERROR] expected three plots\n' >&2
    return 1
  }

  for index in 0 1 2; do
    printf -v node 'node%02d' "$((index + 1))"
    mkdir -p "/opt/sia/plots/${node}"
    mv "${plots[${index}]}" "/opt/sia/plots/${node}/"
  done

  rm -rf "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" "${FINAL_DIR}" "${TEMP_DIR}"
}

main() {
  create_plots
}

main "$@"
