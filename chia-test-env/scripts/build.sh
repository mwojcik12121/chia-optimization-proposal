#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CHIA_BINARY_IMAGE="${CHIA_BINARY_IMAGE:-chia-binaries:built}"
readonly RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-local}"
readonly NODES=(node01 node02 node03 node04 node06 node07 node08 node09)
readonly COMPOSE_FILE="${PROJECT_ROOT}/docker/compose.yaml"

build_target() {
  local target="${1:?target missing}"
  local image="${2:?image missing}"
  DOCKER_BUILDKIT=1 docker build \
    --pull=false \
    --network=none \
    --build-arg "CHIA_BINARY_IMAGE=${CHIA_BINARY_IMAGE}" \
    --target "${target}" \
    --tag "${image}" \
    --file docker/Dockerfile \
    .
}

main() {
  cd "${PROJECT_ROOT}"
  export RUNTIME_IMAGE_TAG
  build_target runtime "chia-runtime200-base:${RUNTIME_IMAGE_TAG}"
  build_target assets "chia-runtime200-assets:${RUNTIME_IMAGE_TAG}"
  docker compose --file "${COMPOSE_FILE}" build --pull=false "${NODES[@]}"
}

main "$@"
