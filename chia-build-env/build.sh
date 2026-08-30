#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly IMAGE_NAME=chia-binaries:built
readonly PACKAGE_PATH="${PROJECT_ROOT}/bin/chia-binaries.tar.gz"
BUILD_JOBS=1
declare -A REPOSITORIES=()

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
  local key directory
  local -a keys=(
    chia-blockchain chia-rs chiapos chiavdf chiabip158
    clvm-rs clvm clvm-tools chialisp chia-puzzles
  )

  [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || build_die '--build-jobs must be a positive integer'
  for key in "${keys[@]}"; do
    directory="${REPOSITORIES[${key}]:-}"
    [[ -n "${directory}" ]] || build_die "--${key} is required"
    [[ -d "${PROJECT_ROOT}/src/${directory}" ]] || build_die "src/${directory} does not exist"
  done
}

build_image() {
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
    .
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
  build_image
  build_package
}

main "$@"
