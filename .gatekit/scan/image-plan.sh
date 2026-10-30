#!/usr/bin/env bash
# image-plan.sh — which Docker images this repo builds, and how.
#
# One line per app folder (APPS in .gatekit/config.yaml) that has a Dockerfile:
#   name<TAB>dockerfile<TAB>build context
# The build context is the app folder, unless the Dockerfile copies paths that start with the app
# folder's name (e.g. `COPY frontend/package.json .`), which means it is built from the repo root.
# SCAN_IMAGES="name:tag ..." in the environment overrides all of this (see run-grype.sh).
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 0

for a in ${GATEKIT_APPS:-.}; do
  [ -f "$a/Dockerfile" ] || continue
  ctx="./$a"
  grep -qE "^[[:space:]]*(COPY|ADD)[^#]*[[:space:]]\.?/?$a/" "$a/Dockerfile" && ctx="."
  printf '%s\t%s/Dockerfile\t%s\n' "$(basename "$a")" "$a" "$ctx"
done
exit 0
