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
COMPOSE_LOG_PID=''
RUN_STARTED=0
LOGS_SAVED=0
BUILD_IMAGES=1

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
  find "${LOG_DIRECTORY}" -maxdepth 1 -type f -name '*.log' -delete
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
  if docker image inspect "${BINARY_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi

  if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    if [[ ! -f "${BINARY_ARCHIVE}" ]]; then
      test_log ERROR runner "binary image ${BINARY_IMAGE} and package ${BINARY_ARCHIVE} are missing"
      return 66
    fi
    docker load --input "${BINARY_ARCHIVE}"
  fi

  if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    test_log ERROR runner "package did not provide image ${BUILDER_IMAGE}"
    return 65
  fi
  if [[ "${BINARY_IMAGE}" != "${BUILDER_IMAGE}" ]]; then
    docker tag "${BUILDER_IMAGE}" "${BINARY_IMAGE}"
  fi
}

run_stop_console_logs() {
  if [[ -n "${COMPOSE_LOG_PID}" ]]; then
    kill "${COMPOSE_LOG_PID}" >/dev/null 2>&1 || true
    wait "${COMPOSE_LOG_PID}" >/dev/null 2>&1 || true
    COMPOSE_LOG_PID=''
  fi
}

run_save_logs() {
  local node container output
  (( RUN_STARTED == 1 && LOGS_SAVED == 0 )) || return 0
  mkdir -p "${LOG_DIRECTORY}"
  for node in "${NODES[@]}"; do
    output="${LOG_DIRECTORY}/${node}_scenario${SCENARIO}_${RUN_DATETIME}.log"
    container="$(run_compose ps --all --quiet "${node}" 2>/dev/null || true)"
    if [[ -n "${container}" ]]; then
      docker logs "${container}" 2>&1 \
        | "${PROJECT_ROOT}/scripts/strip-ansi.sh" >"${output}" \
        || true
    else
      : >"${output}"
    fi
  done
  LOGS_SAVED=1
}

run_cleanup() {
  local status=$?
  trap - EXIT INT TERM
  run_stop_console_logs
  run_save_logs
  if (( RUN_STARTED == 1 )); then
    run_compose down --volumes --remove-orphans --timeout 30 >/dev/null 2>&1 || true
  fi
  exit "${status}"
}

run_container_state() {
  local node="${1:?node missing}"
  local container state code
  container="$(run_compose ps --all --quiet "${node}" 2>/dev/null || true)"
  if [[ -z "${container}" ]]; then
    printf '%s\n' MISSING
    return 0
  fi
  state="$(docker inspect --format '{{.State.Status}}' "${container}")"
  case "${state}" in
    running|created|restarting) printf '%s\n' RUNNING ;;
    *)
      code="$(docker inspect --format '{{.State.ExitCode}}' "${container}")"
      printf 'EXIT:%s\n' "${code}"
      ;;
  esac
}

run_wait() {
  local node state running
  while true; do
    running=0
    for node in "${NODES[@]}"; do
      state="$(run_container_state "${node}")"
      case "${state}" in
        RUNNING) running=$((running + 1)) ;;
        MISSING) return 125 ;;
        EXIT:0) ;;
        EXIT:*) return "${state#EXIT:}" ;;
      esac
    done
    (( running > 0 )) || return 0
    sleep 1
  done
}

run_scenario() {
  export SCENARIO SCENARIO_NODES
  export RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-local}"
  export CHIA_BINARY_IMAGE="${BINARY_IMAGE}"
  export COMPOSE_PROJECT_NAME="chia-runtime200-s${SCENARIO}-$$"
  RUN_DATETIME="$(date +%Y%m%d_%H%M%S)"
  mkdir -p "${LOG_DIRECTORY}"

  if (( BUILD_IMAGES == 1 )); then
    run_prepare_binary_image
    "${PROJECT_ROOT}/scripts/build.sh"
  fi

  RUN_STARTED=1
  run_compose up --detach --no-build "${NODES[@]}"
  run_compose logs --follow --no-color "${NODES[@]}" &
  COMPOSE_LOG_PID=$!
  run_wait
  run_stop_console_logs
  run_save_logs
  test_log INFO runner "logs: logs/nodeXX_scenario${SCENARIO}_${RUN_DATETIME}.log"
}

main() {
  cd "${PROJECT_ROOT}"
  run_parse_arguments "$@"
  run_discover_nodes
  run_require_capacity
  trap run_cleanup EXIT INT TERM
  run_clear_old_logs
  run_remove_stale_networks
  run_scenario
}

main "$@"
