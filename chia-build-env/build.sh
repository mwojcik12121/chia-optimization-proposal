#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly IMAGE_NAME=chia-binaries:built
readonly PACKAGE_PATH="${PROJECT_ROOT}/bin/chia-binaries.tar.gz"
BUILD_JOBS=1
declare -A REPOSITORIES=()
declare -A REPOSITORY_PATHS=()
BUILD_CONTEXT=''

build_usage() {
  cat <<'USAGE'
Usage:
  ./build.sh \
    --chia-blockchain DIRECTORY \
    --chia-rs DIRECTORY \
    --chiapos DIRECTORY \
    --chiavdf DIRECTORY \
    --chiabip158 DIRECTORY \
    --clvm-rs DIRECTORY \
    --clvm DIRECTORY \
    --clvm-tools DIRECTORY \
    --chialisp DIRECTORY \
    --chia-puzzles DIRECTORY \
    [--build-jobs NUMBER]
USAGE
}

build_die() {
  printf '[build][ERROR] %s\n' "$*" >&2
  exit 1
}

build_set_repository() {
  local key="${1:?repository key missing}"
  local directory="${2:?repository directory missing}"
  REPOSITORIES["${key}"]="${directory}"
}

build_parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --chia-blockchain|--chia-rs|--chiapos|--chiavdf|--chiabip158|--clvm-rs|--clvm|--clvm-tools|--chialisp|--chia-puzzles)
        (( $# >= 2 )) || build_die "$1 requires a directory name"
        build_set_repository "${1#--}" "$2"
        shift 2
        ;;
      --build-jobs)
        (( $# >= 2 )) || build_die '--build-jobs requires a number'
        BUILD_JOBS="$2"
        shift 2
        ;;
      -h|--help)
        build_usage
        exit 0
        ;;
      *)
        build_die "unknown option: $1"
        ;;
    esac
  done
}

build_require_repositories() {
  local key directory path
  local -a keys=(
    chia-blockchain chia-rs chiapos chiavdf chiabip158
    clvm-rs clvm clvm-tools chialisp chia-puzzles
  )

  [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || build_die '--build-jobs must be a positive integer'
  for key in "${keys[@]}"; do
    directory="${REPOSITORIES[${key}]:-}"
    [[ -n "${directory}" ]] || build_die "--${key} is required"
    [[ "${directory}" != */* && "${directory}" != . && "${directory}" != .. ]] \
      || build_die "invalid repository directory: ${directory}"
    path="${PROJECT_ROOT}/src/${directory}"
    [[ -d "${path}" ]] || build_die "repository does not exist: ${path}"
    REPOSITORY_PATHS["${key}"]="$(realpath -- "${path}")"
    [[ "${REPOSITORY_PATHS[${key}]}" == "${PROJECT_ROOT}/src/"* ]] \
      || build_die "repository must be inside src: ${directory}"
    REPOSITORIES["${key}"]="${REPOSITORY_PATHS[${key}]##*/}"
  done
}

build_require_consensus_contract() {
  local blockchain_constants chia_rs_constants mapping python_name rust_name
  local -a constant_mappings=(
    'PLOT_FILTER_V2_FIRST_ADJUSTMENT_HEIGHT:plot_filter_v2_first_adjustment_height'
    'PLOT_FILTER_V2_SECOND_ADJUSTMENT_HEIGHT:plot_filter_v2_second_adjustment_height'
    'PLOT_FILTER_V2_THIRD_ADJUSTMENT_HEIGHT:plot_filter_v2_third_adjustment_height'
    'PLOT_FILTER_V2_RELATIVE_HEIGHT:plot_filter_v2_relative_height'
    'FILTER_WINDOW_SIZE:filter_window_size'
    'MAX_EFFECTIVE_PLOT_FILTER_BITS:max_effective_plot_filter_bits'
  )

  blockchain_constants="${REPOSITORY_PATHS[chia-blockchain]}/chia/consensus/default_constants.py"
  chia_rs_constants="${REPOSITORY_PATHS[chia-rs]}/crates/chia-consensus/src/consensus_constants.rs"
  [[ -f "${blockchain_constants}" ]] || build_die "missing consensus constants: ${blockchain_constants}"
  [[ -f "${chia_rs_constants}" ]] || build_die "missing consensus constants: ${chia_rs_constants}"

  for mapping in "${constant_mappings[@]}"; do
    IFS=: read -r python_name rust_name <<<"${mapping}"
    if grep -qE "${python_name}[[:space:]]*=" "${blockchain_constants}" \
      && ! grep -qE "[[:space:]]${rust_name}:[[:space:]]" "${chia_rs_constants}"; then
      build_die \
        "${REPOSITORIES[chia-blockchain]} requires ${python_name}, but ${REPOSITORIES[chia-rs]} does not provide it"
    fi
  done
}

build_image() {
  local key
  # Stage only the selected repositories from src/.
  BUILD_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/chia-build.XXXXXX")"
  trap 'rm -rf -- "${BUILD_CONTEXT}"' EXIT
  mkdir -p "${BUILD_CONTEXT}/src"
  cp "${PROJECT_ROOT}/Dockerfile" "${BUILD_CONTEXT}/Dockerfile"
  cp -a "${PROJECT_ROOT}/scripts" "${BUILD_CONTEXT}/scripts"
  for key in "${!REPOSITORIES[@]}"; do
    cp -a "${REPOSITORY_PATHS[${key}]}" "${BUILD_CONTEXT}/src/${REPOSITORIES[${key}]##*/}"
    REPOSITORIES["${key}"]="${REPOSITORIES[${key}]##*/}"
  done
  DOCKER_BUILDKIT=1 docker build \
    --build-arg "BUILD_JOBS=${BUILD_JOBS}" \
    --build-arg "REPO_CHIA_BLOCKCHAIN=${REPOSITORIES[chia-blockchain]}" \
    --build-arg "REPO_CHIA_RS=${REPOSITORIES[chia-rs]}" \
    --build-arg "REPO_CHIAPOS=${REPOSITORIES[chiapos]}" \
    --build-arg "REPO_CHIAVDF=${REPOSITORIES[chiavdf]}" \
    --build-arg "REPO_CHIABIP158=${REPOSITORIES[chiabip158]}" \
    --build-arg "REPO_CLVM_RS=${REPOSITORIES[clvm-rs]}" \
    --build-arg "REPO_CLVM=${REPOSITORIES[clvm]}" \
    --build-arg "REPO_CLVM_TOOLS=${REPOSITORIES[clvm-tools]}" \
    --build-arg "REPO_CHIALISP=${REPOSITORIES[chialisp]}" \
    --build-arg "REPO_CHIA_PUZZLES=${REPOSITORIES[chia-puzzles]}" \
    --target binary-runtime \
    --tag "${IMAGE_NAME}" \
    --file Dockerfile \
    "${BUILD_CONTEXT}"
}

build_package() {
  local temporary="${PACKAGE_PATH}.tmp"
  mkdir -p "$(dirname "${PACKAGE_PATH}")"
  rm -f "${PACKAGE_PATH}" "${temporary}"
  docker save "${IMAGE_NAME}" | gzip -n -1 > "${temporary}"
  mv "${temporary}" "${PACKAGE_PATH}"
  printf 'Created %s\n' "${PACKAGE_PATH#${PROJECT_ROOT}/}"
}

main() {
  cd "${PROJECT_ROOT}"
  build_parse_arguments "$@"
  build_require_repositories
  build_require_consensus_contract
  build_image
  build_package
}

main "$@"
