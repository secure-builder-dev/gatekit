#!/usr/bin/env bash
# build-images.sh — build each app's Docker image fresh (pulling the newest base image) so the image scanners check what your code builds today.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${SCAN_NO_BUILD:-0}" = "1" ]; then
  echo "[build] SCAN_NO_BUILD=1 — skipping. The scan will measure whatever image already exists."
  exit 0
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[build] docker unavailable — skipping build; image scans will report NOTHING SCANNED."
  exit 0
fi

rc=0; built=0
while IFS="$(printf '\t')" read -r name df ctx; do
  [ -n "$name" ] || continue
  [ -f "$df" ] || { echo "[build] SKIP $name — $df not found"; continue; }
  echo "[build] $name  ($df, context $ctx)  --pull --no-cache"
  if docker build --pull --no-cache -f "$df" -t "${name}:scan" "$ctx"; then
    built=$((built + 1))
  else
    echo "[build] FAILED: $name"; rc=1
  fi
done < <(bash "$SCRIPT_DIR/image-plan.sh" 2>/dev/null)

[ "$built" -eq 0 ] && echo "[build] nothing built — check .gatekit/scan/image-plan.sh"
exit $rc
