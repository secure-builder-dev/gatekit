#!/usr/bin/env bash
# run-grype.sh — scan each built Docker image for known vulnerabilities (CVEs) with Grype.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"

# shellcheck source=tool-runner.sh
. "$SCRIPT_DIR/tool-runner.sh"
# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin grype

if ! have_tool grype; then
  tool_missing grype grype
  exit 1
fi

mkdir -p "$RESULTS_DIR"


if ! command -v docker >/dev/null 2>&1; then
  echo "[grype] Docker not available"
  exit 1
fi

SCANNED=0
IMAGES=()
if [ -n "${SCAN_IMAGES:-}" ]; then
  read -r -a IMAGES <<< "$SCAN_IMAGES"
else
  while IFS="$(printf '\t')" read -r name _df _ctx; do
    [ -n "$name" ] || continue
    for tag in scan local latest; do
      if docker image inspect "${name}:${tag}" >/dev/null 2>&1; then IMAGES+=("${name}:${tag}"); break; fi
    done
  done < <(bash "$SCRIPT_DIR/image-plan.sh" 2>/dev/null)
fi
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("none-built")

# shellcheck source=/dev/null
. "$SCRIPT_DIR/image-age-guard.sh"
guard_image_age "${IMAGES[@]}" || exit 1
GRYPE_JSON_TMP=$(mktemp)
GRYPE_LOG_TMP=$(mktemp)

echo '{"matches":[],"source":{"type":"multi-image"},"descriptor":{"name":"grype","version":"merged"}}' > "$GRYPE_JSON_TMP"

for IMAGE in "${IMAGES[@]}"; do
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[grype] IMAGE NOT FOUND: $IMAGE. Build the image first with docker build."
    continue
  fi

  echo "[grype] Scanning $IMAGE via $(scan_engine) engine..."
  SCANNED=$((SCANNED + 1))
  img_json=$(mktemp)
  img_log=$(mktemp)

  tool_grype "$IMAGE" --output json > "$img_json" 2>"$img_log" || true
  tool_grype "$IMAGE" --output table >> "$GRYPE_LOG_TMP" 2>/dev/null || true

  GRYPE_JSON_TMP_NEXT=$(mktemp)
  jq -s '.[0].matches += .[1].matches | .[0]' "$GRYPE_JSON_TMP" "$img_json" > "$GRYPE_JSON_TMP_NEXT"
  mv "$GRYPE_JSON_TMP_NEXT" "$GRYPE_JSON_TMP"

  rm -f "$img_json" "$img_log"
done

if [ "$SCANNED" -eq 0 ]; then
  rm -f "$GRYPE_JSON_TMP" "$GRYPE_LOG_TMP"
  echo ""
  echo "[grype] NOTHING SCANNED — no images found. This is NOT a clean result."
  echo "         Looked for: ${IMAGES[*]}"
  echo "         Build them first:   docker compose build (or docker build)"
  echo "         Or choose images:   SCAN_IMAGES=\"name:tag name:tag\" make scans"
  exit 1
fi

cp "$GRYPE_JSON_TMP" "$RESULTS_DIR/grype.json"
cp "$GRYPE_LOG_TMP" "$RESULTS_DIR/grype.log"
rm -f "$GRYPE_JSON_TMP" "$GRYPE_LOG_TMP"
scan_ran grype "$SCANNED image(s)"

FINDING_COUNT=$(count_json "$RESULTS_DIR/grype.json" \
  '(.matches // error("no .matches key — output shape changed")) | length' grype) || exit 2
echo "[grype] Complete — $FINDING_COUNT finding(s). Results: $RESULTS_DIR/grype.json"

exit 0
