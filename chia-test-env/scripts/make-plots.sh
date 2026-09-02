#!/usr/bin/env bash
set -Eeuo pipefail

export CHIA_ROOT=/opt/chia/plot-root
export CHIA_KEYS_ROOT=/opt/chia/plot-keys
readonly FINAL_DIR=/opt/chia/plot-output
readonly TEMP_DIR=/opt/chia/plot-temp
readonly MNEMONIC_FILE=/opt/chia/lab-mnemonic.txt

create_plots() {
  local index node
  local -a plots=()

  rm -rf "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" "${FINAL_DIR}" "${TEMP_DIR}" /opt/chia/plots
  mkdir -p "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" "${FINAL_DIR}" "${TEMP_DIR}" /opt/chia/plots

  chia init >/dev/null
  chia keys add --filename "${MNEMONIC_FILE}" --label private200 >/dev/null
  chia init --fix-ssl-permissions >/dev/null
  chia plots create \
    --size 25 \
    --override-k \
    --num 4 \
    --buffer 256 \
    --num_threads 2 \
    --buckets 64 \
    --tmp_dir "${TEMP_DIR}" \
    --final_dir "${FINAL_DIR}" \
    --exclude_final_dir

  mapfile -d '' -t plots < <(find "${FINAL_DIR}" -maxdepth 1 -type f -name '*.plot' -print0 | sort -z)
  (( ${#plots[@]} == 4 )) || {
    printf '[plot-assets][ERROR] expected four plots\n' >&2
    return 1
  }

  for index in 0 1 2 3; do
    printf -v node 'node%02d' "$((index + 1))"
    mkdir -p "/opt/chia/plots/${node}"
    mv "${plots[${index}]}" "/opt/chia/plots/${node}/"
  done

  rm -rf "${CHIA_ROOT}" "${CHIA_KEYS_ROOT}" "${FINAL_DIR}" "${TEMP_DIR}"
}

main() {
  create_plots
}

main "$@"
