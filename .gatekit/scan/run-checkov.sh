#!/usr/bin/env bash
# run-checkov.sh — scan infrastructure-as-code (a helm/ chart and terraform/, when present) with Checkov.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"

# shellcheck source=tool-runner.sh
. "$SCRIPT_DIR/tool-runner.sh"
# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin checkov

if ! have_tool checkov; then
  tool_missing checkov checkov
  exit 1
fi

mkdir -p "$RESULTS_DIR"

combined_failed=0
frameworks_scanned=0
combined_json='{"results":{"passed_checks":[],"failed_checks":[],"skipped_checks":[]},"summary":{"passed":0,"failed":0,"skipped":0,"parsing_error":0,"resource_count":0}}'

run_framework() {
  local framework="$1"
  local target="$2"
  local label="$3"

  if [[ ! -d "$PROJECT_ROOT/$target" ]]; then
    echo "[checkov] $label directory not found — skipping $framework scan"
    return 0
  fi
  frameworks_scanned=$((frameworks_scanned + 1))

  echo "[checkov] Scanning $label ($framework) via $(scan_engine) engine..."
  local tmp_json
  tmp_json=$(mktemp)

  tool_checkov \
    --framework "$framework" \
    --directory "$target" \
    --output json \
    --quiet \
    > "$tmp_json" 2>/dev/null || true

  if [[ ! -s "$tmp_json" ]]; then
    echo "[checkov] FAIL — $label produced no output. The scanner did not run." >&2
    rm -f "$tmp_json"
    return 2
  fi

  if ! jq -e 'has("results")' "$tmp_json" >/dev/null 2>&1; then
    local rc; rc=$(jq -r '.resource_count // "unknown"' "$tmp_json" 2>/dev/null || echo unknown)
    echo "[checkov] $label — NOTHING SCANNED: checkov parsed 0 resources (resource_count=$rc)."
    echo "[checkov]   This is not a pass. Check that the target is the right shape for the"
    echo "[checkov]   $framework framework — the helm framework wants a chart root with Chart.yaml,"
    echo "[checkov]   not a templates directory."
    rm -f "$tmp_json"
    return 0
  fi

  if true; then
    local fail_count
    fail_count=$(count_json "$tmp_json" \
      '(.results.failed_checks // error("no .results.failed_checks — output shape changed")) | length' \
      checkov) || { rm -f "$tmp_json"; return 2; }
    combined_failed=$((combined_failed + fail_count))
    combined_json=$(jq -s '
      .[0].results.failed_checks += .[1].results.failed_checks |
      .[0].results.passed_checks += .[1].results.passed_checks |
      .[0].summary.failed += .[1].summary.failed |
      .[0].summary.passed += .[1].summary.passed |
      .[0]
    ' <(echo "$combined_json") "$tmp_json" 2>/dev/null || echo "$combined_json")
  fi
  rm -f "$tmp_json"
}

run_framework "helm"      "helm"            "helm chart"     || exit 2
run_framework "terraform" "terraform"       "terraform"       || exit 2

echo "$combined_json" > "$RESULTS_DIR/checkov.json"
jq -r '.results.failed_checks[]? | "\(.check_id)  \(.file_path // "?")  \(.check_name // "")"' "$RESULTS_DIR/checkov.json" > "$RESULTS_DIR/checkov.log" 2>/dev/null || true

echo "[checkov] Results: $combined_failed total failed before justification"
if ! bash "$SCRIPT_DIR/checkov-decide.sh" "$RESULTS_DIR/checkov.json"; then
  echo "[checkov] FAIL — see $RESULTS_DIR/checkov.json"
  exit 1
fi

if [ "$frameworks_scanned" -gt 0 ]; then
  scan_ran checkov "$frameworks_scanned framework(s)"
else
  scan_none checkov "no helm/ or terraform/ directory to scan"
fi
