#!/usr/bin/env bash
# run-hadolint.sh — lint every Dockerfile in your app folders with hadolint (settings: .gatekit/scan/hadolint.yaml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"

# shellcheck source=tool-runner.sh
. "$SCRIPT_DIR/tool-runner.sh"
# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin hadolint

if ! have_tool hadolint; then
  tool_missing hadolint hadolint
  exit 1
fi

mkdir -p "$RESULTS_DIR"

DOCKERFILES=()
SKIPPED_IGNORED=0
while IFS= read -r -d $'\0' f; do
  rel="${f#"$PROJECT_ROOT"/}"
  if git -C "$PROJECT_ROOT" check-ignore -q "$rel" 2>/dev/null; then
    SKIPPED_IGNORED=$((SKIPPED_IGNORED + 1)); continue
  fi
  DOCKERFILES+=("$rel")
done < <(for _a in ${GATEKIT_APPS:-.}; do printf "%s\0" "$PROJECT_ROOT/$_a"; done | xargs -0 -I{} find {} \
  -maxdepth 2 -not -path "*/node_modules/*" \
  \( -name "Dockerfile" -o -name "Dockerfile.*" \) \
  -print0 2>/dev/null) || true
[[ "$SKIPPED_IGNORED" -gt 0 ]] && \
  echo "[hadolint] Skipping $SKIPPED_IGNORED gitignored Dockerfile(s) — reference copies, not shipped."

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "[hadolint] No Dockerfiles found in: ${GATEKIT_APPS:-.}"
  echo "[]" > "$RESULTS_DIR/hadolint.json"
  printf '' > "$RESULTS_DIR/hadolint.log"
  scan_none hadolint "no Dockerfiles in ${GATEKIT_APPS:-.}"
  exit 0
fi

echo "[hadolint] Scanning ${#DOCKERFILES[@]} Dockerfile(s) via $(scan_engine) engine..."

tool_hadolint --format json --config .gatekit/scan/hadolint.yaml "${DOCKERFILES[@]}" \
  > "$RESULTS_DIR/hadolint.json" 2>"$RESULTS_DIR/hadolint.stderr" || true

tool_hadolint --format tty --config .gatekit/scan/hadolint.yaml "${DOCKERFILES[@]}" \
  > "$RESULTS_DIR/hadolint.log" 2>&1 || true

ERROR_COUNT=$(count_json "$RESULTS_DIR/hadolint.json" '[.[] | select(.level == "error")] | length' hadolint) || exit 2
WARN_COUNT=$(count_json "$RESULTS_DIR/hadolint.json" '[.[] | select(.level == "warning")] | length' hadolint) || exit 2

echo "[hadolint] Results: $ERROR_COUNT error(s), $WARN_COUNT warning(s)"

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  echo "[hadolint] FAIL — $ERROR_COUNT error-level finding(s). See $RESULTS_DIR/hadolint.json"
  exit 1
fi

scan_ran hadolint "${#DOCKERFILES[@]} Dockerfile(s)"
echo "[hadolint] PASS"
exit 0
