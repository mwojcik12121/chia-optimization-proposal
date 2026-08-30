#!/usr/bin/env bash
set -Eeuo pipefail

readonly CERT_SEED_ROOT=/opt/sia/cert-seed
readonly CERT_WORK_ROOT=/opt/sia/cert-work
readonly CERT_OUTPUT_ROOT=/opt/sia/certs
readonly CERT_KEYS_ROOT=/opt/sia/cert-keys

create_shared_ca() {
  export CHIA_ROOT="${CERT_SEED_ROOT}"
  export CHIA_KEYS_ROOT="${CERT_KEYS_ROOT}"
  rm -rf "${CERT_SEED_ROOT}" "${CERT_KEYS_ROOT}"
  mkdir -p "${CERT_SEED_ROOT}"
  chia init >/dev/null
}

create_node_certificates() {
  local node_id="${1:?node ID missing}"
  local node_root="${CERT_WORK_ROOT}/node${node_id}"
  local node_output="${CERT_OUTPUT_ROOT}/node${node_id}"

  export CHIA_ROOT="${node_root}"
  export CHIA_KEYS_ROOT="${CERT_KEYS_ROOT}"
  rm -rf "${node_root}" "${node_output}"
  mkdir -p "${node_root}/config" "${node_output}"
  cp "${CERT_SEED_ROOT}/config/config.yaml" "${node_root}/config/config.yaml"
  chia init -c "${CERT_SEED_ROOT}/config/ssl/ca" --fix-ssl-permissions >/dev/null
  cp -a "${node_root}/config/ssl" "${node_output}/ssl"
  rm -f \
    "${node_output}/ssl/ca/private_ca.key" \
    "${node_output}/ssl/ca/chia_ca.key"
}

create_all_certificates() {
  local node_id
  rm -rf "${CERT_WORK_ROOT}" "${CERT_OUTPUT_ROOT}"
  mkdir -p "${CERT_WORK_ROOT}" "${CERT_OUTPUT_ROOT}"
  create_shared_ca
  for node_id in 01 02 03 04 05 06 07 08 09; do
    create_node_certificates "${node_id}"
  done
  rm -rf "${CERT_SEED_ROOT}" "${CERT_WORK_ROOT}" "${CERT_KEYS_ROOT}"
}

main() {
  create_all_certificates
}

main "$@"
