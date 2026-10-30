#!/usr/bin/env bash
# scans.sh — `make scans`.
#
#   1. Run every scanner.
#   2. If anything is fixable, run make patch (which fixes, tests, commits and re-scans).
#   3. Copy the POAM list into this branch's records and print the one-line verdict.
#
# GK_NO_PATCH=1 skips step 2 (patch.sh sets it when it re-scans, so they don't loop).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
S="$GK_DIR/scan"

mkdir -p "$SCAN_RESULTS_DIR"
gk_say "scanning $GK_BRANCH (results in ${SCAN_RESULTS_DIR#$GK_ROOT/})"

bash "$S/pull-images.sh"
bash "$S/build-images.sh"
for r in run-hadolint run-checkov run-clamav run-grype run-trivy run-npm-audit run-eslint; do
  bash "$S/$r.sh" || true
done
bash "$S/generate-dispatch.sh" || true

if [ -f "$SCAN_RESULTS_DIR/dispatch.md" ] && [ "${GK_NO_PATCH:-0}" != 1 ]; then
  echo ""
  gk_say "found fixable problems — running make patch"
  exec bash "$GK_DIR/patch.sh"
fi

# The POAM list travels with the branch; raw scanner output does not (it's gitignored).
if [ -f "$SCAN_RESULTS_DIR/poam-candidates.md" ]; then
  cp "$SCAN_RESULTS_DIR/poam-candidates.md" "$GK_REC/poam-candidates.md"
else
  rm -f "$GK_REC/poam-candidates.md"
fi

echo ""
GATE_LINE_STAMP=1 bash "$S/gate-line.sh" | tee "$GK_REC/scan-verdict.txt"
rc=${PIPESTATUS[0]}
gk_commit_records "gatekit: scan results"
[ -f "$GK_REC/poam-candidates.md" ] && gk_say "no-fix-yet problems for your POAM: ${GK_REC#$GK_ROOT/}/poam-candidates.md (see .gatekit/POAM-GUIDE.md)"
exit "$rc"
