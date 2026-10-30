#!/usr/bin/env bash
# gate-line.sh — print the one-line scan verdict (PASS/FAIL, scanners that ran, fixable count, POAM count). With GATE_LINE_STAMP=1 it also records which commit was scanned.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 0
R="${SCAN_RESULTS_DIR:-.gatekit/records/scan-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_RECEIPT_DIR="$R"
# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

if [ ! -d "$R" ] || [ -z "$(ls -A "$R" 2>/dev/null)" ]; then
  echo "Scan: NOT RUN — no results at $R. This is not a pass; run \`make scans\`."
  exit 1
fi

SCANNERS=("hadolint:hadolint.json" "checkov:checkov.json" "clamav:clamav.log" \
          "grype:grype.json" "trivy:trivy.json" "npm-audit:audit.json" "eslint:eslint.json")
TOTAL=${#SCANNERS[@]}

if ! command -v jq >/dev/null 2>&1; then
  echo "Scan: FAIL — jq is not installed, so no result file can be validated. This is not a pass."
  exit 1
fi

RAN=0; MISSING=""; EMPTY_SCOPE=""
for pair in "${SCANNERS[@]}"; do
  name="${pair%%:*}"; file="$R/${pair#*:}"

  kind="$(scan_receipt_kind "$name")"
  if [ -z "$kind" ]; then MISSING="$MISSING $name"; continue; fi

  if [ ! -s "$file" ]; then MISSING="$MISSING $name(no result)"; continue; fi
  case "${pair#*:}" in
    *.json)
      jq -e . "$file" >/dev/null 2>&1 || { MISSING="$MISSING $name(unreadable)"; continue; } ;;
    clamav.log)
      grep -q 'Infected files:' "$file" || { MISSING="$MISSING $name(no summary)"; continue; } ;;
  esac

  RAN=$((RAN+1))
  [ "$kind" = none ] && EMPTY_SCOPE="$EMPTY_SCOPE $name"
done

FIXABLE=0; POAM=0; MALWARE=no
[ -f "$R/dispatch.md" ]        && { FIXABLE=$(grep -c '^### ' "$R/dispatch.md" 2>/dev/null); FIXABLE=${FIXABLE:-0}; }
[ -f "$R/poam-candidates.md" ] && { POAM=$(grep -c '^## '  "$R/poam-candidates.md" 2>/dev/null); POAM=${POAM:-0}; }
[ -f "$R/dispatch.md" ] && grep -q 'INFECTION DETECTED' "$R/dispatch.md" 2>/dev/null && MALWARE=yes

BLOCKING=no
[ -f "$R/dispatch.md" ] && BLOCKING=yes
[ "$RAN" -lt "$TOTAL" ] && BLOCKING=yes

VERDICT=PASS
[ "$BLOCKING" = yes ] && VERDICT=FAIL

printf 'Scan: %s — %s/%s scanners ran%s%s · %s fixable%s · %s POAM candidate(s), not blocking\n' \
  "$VERDICT" "$RAN" "$TOTAL" "${MISSING:+ (did not run:$MISSING)}" \
  "${EMPTY_SCOPE:+ (nothing in scope:$EMPTY_SCOPE)}" "$FIXABLE" \
  "$([ "$MALWARE" = yes ] && printf ' · MALWARE DETECTED')" "$POAM"

if [ "${GATE_LINE_STAMP:-0}" = 1 ]; then
  printf '%s %s %s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$VERDICT" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$R/.scan-stamp" 2>/dev/null || true
fi

[ "$VERDICT" = PASS ] || exit 1
exit 0
