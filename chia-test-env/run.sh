#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PROJECT_ROOT}/controls/logging.sh"

readonly NODES=(node01 node02 node03 node04 node06 node07 node08 node09)
readonly LOG_DIRECTORY="${PROJECT_ROOT}/logs"
readonly COMPOSE_FILE="${PROJECT_ROOT}/docker/compose.yaml"
readonly SCENARIO_DIRECTORY="${PROJECT_ROOT}/scenarios"
readonly BINARY_ARCHIVE="${CHIA_BINARY_ARCHIVE:-${PROJECT_ROOT}/bin/chia-binaries.tar.gz}"
readonly BUILDER_IMAGE="${CHIA_BUILDER_IMAGE:-chia-binaries:built}"
readonly BINARY_IMAGE="${CHIA_BINARY_IMAGE:-chia-binaries:built}"
readonly REQUIRED_DOCKER_CPUS=8
readonly REQUIRED_DOCKER_MEMORY_BYTES=24000000000
readonly REQUIRED_HOST_STORAGE_BYTES=750000000000
SCENARIO=''
SCENARIO_NODES=''
RUN_DATETIME=''
RUN_STARTED=0
LOGS_INITIALIZED=0
LOGS_SAVED=0
BUILD_IMAGES=1
BINARY_PACKAGE_SHA256='unknown'

run_usage() {
  cat <<'USAGE'
Usage: ./run.sh SCENARIO [--no-build]
USAGE
}

run_parse_arguments() {
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    run_usage
    exit 0
  fi
  SCENARIO="${1:?scenario number required}"
  shift
  while (( $# > 0 )); do
    case "$1" in
      --no-build) BUILD_IMAGES=0 ;;
      *) test_log ERROR runner "unknown option: $1"; return 64 ;;
    esac
    shift
  done
}

run_discover_nodes() {
  local file name node
  local -a files selected
  shopt -s nullglob
  files=("${SCENARIO_DIRECTORY}"/node??_scenario"${SCENARIO}".sh)
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || {
    test_log ERROR runner "no scenario ${SCENARIO} files found"
    return 66
  }
  for file in "${files[@]}"; do
    name="${file##*/}"
    node="${name%%_scenario*}"
    selected+=("${node}")
  done
  SCENARIO_NODES="$(IFS=,; printf '%s' "${selected[*]}")"
}

run_compose() {
  docker compose --file "${COMPOSE_FILE}" "$@"
}

run_require_capacity() {
  local docker_capacity docker_cpus docker_memory host_storage
  docker_capacity="$(docker info --format '{{.NCPU}} {{.MemTotal}}')" || {
    test_log ERROR runner 'unable to read Docker resource capacity'
    return 1
  }
  read -r docker_cpus docker_memory <<<"${docker_capacity}"
  if [[ ! "${docker_cpus}" =~ ^[0-9]+$ || ! "${docker_memory}" =~ ^[0-9]+$ ]]; then
    test_log ERROR runner "invalid Docker capacity: ${docker_capacity}"
    return 1
  fi
  if (( docker_cpus < REQUIRED_DOCKER_CPUS )); then
    test_log ERROR runner \
      "Docker exposes ${docker_cpus} CPUs; at least ${REQUIRED_DOCKER_CPUS} are required"
    return 1
  fi
  if (( docker_memory < REQUIRED_DOCKER_MEMORY_BYTES )); then
    test_log ERROR runner \
      "Docker exposes ${docker_memory} bytes of RAM; at least ${REQUIRED_DOCKER_MEMORY_BYTES} are required"
    return 1
  fi

  host_storage="$(df -PB1 "${PROJECT_ROOT}" | awk 'NR == 2 {print $4}')"
  if [[ ! "${host_storage}" =~ ^[0-9]+$ ]]; then
    test_log ERROR runner 'unable to determine available host storage'
    return 1
  fi
  if (( host_storage < REQUIRED_HOST_STORAGE_BYTES )); then
    test_log ERROR runner \
      "host has ${host_storage} bytes free; at least ${REQUIRED_HOST_STORAGE_BYTES} are required"
    return 1
  fi
}

run_clear_old_logs() {
  mkdir -p "${LOG_DIRECTORY}"
  find "${LOG_DIRECTORY}" -mindepth 1 -maxdepth 1 ! -name README.md -exec rm -rf -- {} +
}

run_log_path() {
  local node="${1:?node missing}"
  printf '%s/%s_scenario%s_%s.log\n' \
    "${LOG_DIRECTORY}" "${node}" "${SCENARIO}" "${RUN_DATETIME}"
}

run_initialize_logs() {
  local node
  RUN_DATETIME="$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${LOG_DIRECTORY}"
  for node in "${NODES[@]}"; do
    : >"$(run_log_path "${node}")"
  done
  LOGS_INITIALIZED=1
}

run_remove_stale_networks() {
  local container_count network
  while IFS= read -r network; do
    [[ "${network}" =~ ^chia-runtime200-s[0-9]+-[0-9]+_internal$ ]] || continue
    container_count="$(
      docker network inspect --format '{{len .Containers}}' "${network}" 2>/dev/null \
        || true
    )"
    [[ "${container_count}" == 0 ]] || continue
    if docker network rm "${network}" >/dev/null 2>&1; then
      test_log INFO runner "removed stale Docker network: ${network}"
    fi
  done < <(docker network ls --format '{{.Name}}')
}

run_prepare_binary_image() {
  local archive_sha=''

  if [[ -f "${BINARY_ARCHIVE}" ]]; then
    archive_sha="$(sha256sum "${BINARY_ARCHIVE}" | awk '{print $1}')"
    BINARY_PACKAGE_SHA256="${archive_sha}"
    test_log INFO runner "loading binary package sha256=${archive_sha}"
    docker load --input "${BINARY_ARCHIVE}"
  elif ! docker image inspect "${BINARY_IMAGE}" >/dev/null 2>&1 \
      && ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    test_log ERROR runner "binary image ${BINARY_IMAGE} and package ${BINARY_ARCHIVE} are missing"
    return 66
  fi

  if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    test_log ERROR runner "package did not provide image ${BUILDER_IMAGE}"
    return 65
  fi
  if [[ "${BINARY_IMAGE}" != "${BUILDER_IMAGE}" ]]; then
    docker tag "${BUILDER_IMAGE}" "${BINARY_IMAGE}"
  fi
  if [[ "${BINARY_PACKAGE_SHA256}" == unknown ]]; then
    BINARY_PACKAGE_SHA256="$(docker image inspect --format '{{.Id}}' "${BINARY_IMAGE}" | sed 's/^sha256://')"
  fi
}

run_identify_preloaded_binary_image() {
  if ! docker image inspect "${BINARY_IMAGE}" >/dev/null 2>&1; then
    test_log ERROR runner "binary image ${BINARY_IMAGE} is missing"
    return 66
  fi
  BINARY_PACKAGE_SHA256="$(docker image inspect --format '{{.Id}}' "${BINARY_IMAGE}" | sed 's/^sha256://')"
}

run_append_chia_logs() {
  local directory="${1:?log directory missing}"
  local output="${2:?output file missing}"
  local file
  [[ -d "${directory}" ]] || return 0

  # Chia rotates debug.log as debug.log.1, debug.log.2, ... . Append the
  # oldest rotation first and the active file last.
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    cat "${directory}/${file}" >>"${output}"
  done < <(
    find "${directory}" -maxdepth 1 -type f -name 'debug.log*' -printf '%f\n' \
      | sort -V -r
  )
}

run_save_logs() {
  local node container output temporary
  (( LOGS_INITIALIZED == 1 && LOGS_SAVED == 0 )) || return 0
  mkdir -p "${LOG_DIRECTORY}"

  for node in "${NODES[@]}"; do
    output="$(run_log_path "${node}")"
    : >"${output}"
    container="$(run_compose ps --all --quiet "${node}" 2>/dev/null || true)"
    [[ -n "${container}" ]] || continue

    temporary="$(mktemp -d)"
    mkdir -p "${temporary}/chia-log"
    docker cp "${container}:/run/chia/root/log/." "${temporary}/chia-log/" 2>/dev/null || true
    run_append_chia_logs "${temporary}/chia-log" "${output}"
    rm -rf "${temporary}"
  done
  LOGS_SAVED=1
}

run_cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if (( RUN_STARTED == 1 )); then
    # Preserve Chia's own application logs before removing the containers.
    # Docker/Compose output stays terminal-only and result JSON is not copied.
    run_compose stop --timeout 120 >/dev/null 2>&1 || true
    run_save_logs
    run_compose down --volumes --remove-orphans --timeout 120 || true
  fi
  if (( status == 0 )); then
    test_log INFO runner "Chia logs: ${LOG_DIRECTORY}/nodeXX_scenario${SCENARIO}_${RUN_DATETIME}.log"
  else
    test_log ERROR runner "scenario failed with exit code ${status}; Chia logs: ${LOG_DIRECTORY}"
  fi
  exit "${status}"
}

run_scenario() {
  export SCENARIO SCENARIO_NODES
  export RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-local}"
  export CHIA_BINARY_IMAGE="${BINARY_IMAGE}"
  export COMPOSE_PROJECT_NAME="chia-runtime200-s${SCENARIO}-$$"

  if (( BUILD_IMAGES == 1 )); then
    run_prepare_binary_image
  else
    run_identify_preloaded_binary_image
  fi
  export CHIA_BINARY_PACKAGE_SHA256="${BINARY_PACKAGE_SHA256}"

  if (( BUILD_IMAGES == 1 )); then
    "${PROJECT_ROOT}/scripts/build.sh"
  fi

  RUN_STARTED=1
  # Run Compose attached instead of following logs from a background process.
  # This restores Compose's native color/progress handling and lets it reset the
  # terminal normally when the scenario ends. Chia debug.log is not emitted by
  # the containers and is copied separately after shutdown.
  run_compose up --no-build --abort-on-container-failure "${NODES[@]}"
  run_save_logs
}

main() {
  cd "${PROJECT_ROOT}"
  run_parse_arguments "$@"
  run_discover_nodes
  run_clear_old_logs
  run_initialize_logs
  trap run_cleanup EXIT INT TERM
  run_require_capacity
  run_remove_stale_networks
  run_scenario
}

main "$@"
