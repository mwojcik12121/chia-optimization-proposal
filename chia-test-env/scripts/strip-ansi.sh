#!/usr/bin/env bash
set -Eeuo pipefail

LC_ALL=C sed $'s/\033\\[[0-9;:]*m//g' "$@"
