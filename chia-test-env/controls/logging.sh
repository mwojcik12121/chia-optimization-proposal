#!/usr/bin/env bash

test_log() {
  local severity="${1:-INFO}"
  local component="${2:-runtime}"
  shift 2 || true

  printf '%s %-8s [%s][%s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S.%3N')" \
    "${severity}" \
    "${NODE_NAME:-runner}" \
    "${component}" \
    "$*" >&2
}
