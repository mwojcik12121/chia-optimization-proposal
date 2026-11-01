#!/usr/bin/env bash

test_log() {
  local severity="${1:-INFO}"
  local component="${2:-runtime}"
  local line
  shift 2 || true

  printf -v line '%s %-8s [%s][%s] %s' \
    "$(date '+%Y-%m-%dT%H:%M:%S.%3N')" \
    "${severity}" \
    "${NODE_NAME:-runner}" \
    "${component}" \
    "$*"

  printf '%s\n' "${line}" >&2
}
