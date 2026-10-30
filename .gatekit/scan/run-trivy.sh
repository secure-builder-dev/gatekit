#!/usr/bin/env bash
# run-trivy.sh — scan each built Docker image for known vulnerabilities (CVEs) with Trivy. Findings both Grype and Trivy agree on are the strongest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"

# shellcheck source=tool-runner.sh
. "$SCRIPT_DIR/tool-runner.sh"
# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin trivy

if ! have_tool trivy; then
  tool_missing trivy trivy
  exit 1
fi

mkdir -p "$RESULTS_DIR"


if ! command -v docker >/dev/null 2>&1; then
  echo "[trivy] Docker not available"
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
TRIVY_JSON_TMP=$(mktemp)
TRIVY_LOG_TMP=$(mktemp)

echo '{"SchemaVersion":2,"Results":[]}' > "$TRIVY_JSON_TMP"

for IMAGE in "${IMAGES[@]}"; do
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[trivy] IMAGE NOT FOUND: $IMAGE. Build the image first with docker build."
    continue
  fi

  echo "[trivy] Scanning $IMAGE via $(scan_engine) engine..."
  SCANNED=$((SCANNED + 1))
  img_json=$(mktemp)

  tool_trivy image --format json --quiet "$IMAGE" > "$img_json" 2>/dev/null || true
  tool_trivy image --format table --quiet "$IMAGE" >> "$TRIVY_LOG_TMP" 2>/dev/null || true

  TRIVY_JSON_TMP_NEXT=$(mktemp)
  jq -s '.[0].Results += (.[1].Results // []) | .[0]' "$TRIVY_JSON_TMP" "$img_json" > "$TRIVY_JSON_TMP_NEXT"
  mv "$TRIVY_JSON_TMP_NEXT" "$TRIVY_JSON_TMP"

  rm -f "$img_json"
done

if [ "$SCANNED" -eq 0 ]; then
  rm -f "$TRIVY_JSON_TMP" "$TRIVY_LOG_TMP"
  echo ""
  echo "[trivy] NOTHING SCANNED — no images found. This is NOT a clean result."
  echo "         Looked for: ${IMAGES[*]}"
  echo "         Build them first:   docker compose build (or docker build)"
  echo "         Or choose images:   SCAN_IMAGES=\"name:tag name:tag\" make scans"
  exit 1
fi

cp "$TRIVY_JSON_TMP" "$RESULTS_DIR/trivy.json"
cp "$TRIVY_LOG_TMP" "$RESULTS_DIR/trivy.log"
rm -f "$TRIVY_JSON_TMP" "$TRIVY_LOG_TMP"
scan_ran trivy "$SCANNED image(s)"

FINDING_COUNT=$(count_json "$RESULTS_DIR/trivy.json" '[.Results[]? | .Vulnerabilities[]?] | length' trivy) || exit 2
echo "[trivy] Complete — $FINDING_COUNT finding(s). Results: $RESULTS_DIR/trivy.json"

exit 0
