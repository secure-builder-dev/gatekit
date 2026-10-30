#!/usr/bin/env bash
# pull-images.sh — pull every scanner image before scanning. A failed pull fails the scan: no scanner, no result.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tool-runner.sh
. "$SCRIPT_DIR/tool-runner.sh"

if [ "$(scan_engine)" != container ]; then
  echo "[pull] SCAN_ENGINE=$(scan_engine) — host binaries, nothing to pull"
  exit 0
fi

failed=0
for ref in "$SCAN_IMAGE_HADOLINT" "$SCAN_IMAGE_CHECKOV" "$SCAN_IMAGE_GRYPE" "$SCAN_IMAGE_TRIVY"; do
  if docker pull -q "$ref" >/dev/null 2>&1; then echo "[pull] $ref"; else echo "[pull] FAIL — could not pull $ref"; failed=1; fi
done
# shellcheck disable=SC2046
if docker pull -q $(_tr_clamav_platform) "$SCAN_IMAGE_CLAMAV" >/dev/null 2>&1; then echo "[pull] $SCAN_IMAGE_CLAMAV"; else echo "[pull] FAIL — could not pull $SCAN_IMAGE_CLAMAV"; failed=1; fi

[ "$failed" -eq 0 ] || { echo "[pull] FAIL — a scanner image is missing; the scan cannot be complete."; exit 1; }
echo "[pull] all scanner images present"
exit 0
