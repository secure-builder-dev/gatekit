#!/usr/bin/env bash
# run-clamav.sh — scan the repo for malware with ClamAV, using fresh virus signatures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"

# shellcheck source=tool-runner.sh
. "$SCRIPT_DIR/tool-runner.sh"
# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin clamav

SCAN_TARGET="${SCAN_DIR_OVERRIDE:-$PROJECT_ROOT}"

if ! have_tool clamscan; then
  tool_missing clamav clamscan
  exit 1
fi

CLAMAV_MAX_AGE_DAYS="${CLAMAV_MAX_AGE_DAYS:-7}"

mkdir -p "$RESULTS_DIR"

clamav_version_line() {
  tool_clamscan "$SCAN_TARGET" --version 2>&1 | head -1 || true
}

clamav_age_from() {
  local v epoch now
  v=$(printf '%s' "${1:-}" | awk -F'/' '{print $3}')
  [ -n "$v" ] || return 1
  epoch=$(date -d "$v" +%s 2>/dev/null || date -j -f "%a %b %d %T %Y" "$v" +%s 2>/dev/null || echo 0)
  [ "$epoch" != 0 ] || return 1
  now=$(date +%s)
  echo $(( (now - epoch) / 86400 ))
}

VERSION_LINE=$(clamav_version_line)
AGE_DAYS=$(clamav_age_from "$VERSION_LINE" || echo "")
SIG_STATE=ok

if [ -z "$AGE_DAYS" ] || [ "$AGE_DAYS" -gt "$CLAMAV_MAX_AGE_DAYS" ]; then
  if [ -n "$AGE_DAYS" ]; then
    echo "[clamav] Signatures are $AGE_DAYS days old (max $CLAMAV_MAX_AGE_DAYS) — refreshing..."
  else
    echo "[clamav] Could not read a signature date — refreshing before deciding anything..."
  fi

  FRESHCLAM_EXIT=0
  tool_freshclam > "$RESULTS_DIR/freshclam.log" 2>&1 || FRESHCLAM_EXIT=$?

  if [ "$FRESHCLAM_EXIT" -eq 0 ]; then
    VERSION_LINE=$(clamav_version_line)
    AGE_DAYS=$(clamav_age_from "$VERSION_LINE" || echo "")
    [ -n "$AGE_DAYS" ] && echo "[clamav] Signatures refreshed — now $AGE_DAYS day(s) old."
  else
    echo "[clamav] FRESHCLAM FAILED (exit $FRESHCLAM_EXIT) — last 15 lines:"
    tail -n 15 "$RESULTS_DIR/freshclam.log" 2>/dev/null | sed 's/^/[clamav]   /'
  fi
fi

if [ -z "$AGE_DAYS" ]; then
  if [ "${CLAMAV_ALLOW_UNVERIFIED_SIGNATURES:-0}" = 1 ]; then
    echo "[clamav] WARNING — signature age UNVERIFIED, proceeding on CLAMAV_ALLOW_UNVERIFIED_SIGNATURES=1."
    echo "[clamav]   The scan will run, but its result is not a clean bill of health."
    SIG_STATE=unverified
  else
    echo "[clamav] UNVERIFIED SIGNATURES — no signature date, and a refresh did not produce one."
    echo "[clamav]   clamscan --version said: ${VERSION_LINE:-(no output)}"
    echo "[clamav]   Refusing to report a scan as clean when the signature age is unknown."
    echo "[clamav]   If you accept that risk: CLAMAV_ALLOW_UNVERIFIED_SIGNATURES=1"
    exit 1
  fi
elif [ "$AGE_DAYS" -gt "$CLAMAV_MAX_AGE_DAYS" ]; then
  echo "[clamav] STALE SIGNATURES — $AGE_DAYS days old (max $CLAMAV_MAX_AGE_DAYS) after a refresh."
  if [ "$(scan_engine)" = container ]; then
    echo "[clamav]   freshclam could not reach the signature mirrors, or they are behind."
    echo "[clamav]   Check outbound access to database.clamav.net, then re-run."
    echo "[clamav]   Details: $RESULTS_DIR/freshclam.log"
  else
    echo "[clamav]   Run: freshclam   (it may need sudo to write /var/lib/clamav)"
  fi
  exit 1
else
  echo "[clamav] Signature database: $AGE_DAYS day(s) old"
fi

echo "[clamav] Scanning $SCAN_TARGET via $(scan_engine) engine..."
tool_clamscan "$SCAN_TARGET" \
  --recursive \
  --infected \
  --exclude-dir='^.*/(\.git|node_modules|.gatekit/records)(/|$)' \
  > "$RESULTS_DIR/clamav.log" 2>&1 || CLAMAV_EXIT=$?

CLAMAV_EXIT="${CLAMAV_EXIT:-0}"
if ! grep -q 'Infected files:' "$RESULTS_DIR/clamav.log"; then
  echo "[clamav] FAIL — clamav.log has no 'Infected files:' summary, so the scan did not complete."
  echo "[clamav]   log begins: $(head -c 160 "$RESULTS_DIR/clamav.log" | tr '\n' ' ')"
  mv -f "$RESULTS_DIR/clamav.log" "$RESULTS_DIR/clamav.log.incomplete" 2>/dev/null \
    && echo "[clamav]   moved aside to clamav.log.incomplete — the results directory now shows clamav as not run"
  exit 2
fi

INFECTED=$(grep -oE 'Infected files: [0-9]+' "$RESULTS_DIR/clamav.log" | grep -oE '[0-9]+' || echo "0")

if [[ "$INFECTED" -gt 0 ]]; then
  echo "[clamav] INFECTION DETECTED — DO NOT COMMIT. See $RESULTS_DIR/clamav.log."
  exit 1
fi

if [[ "$CLAMAV_EXIT" -ne 0 ]]; then
  echo "[clamav] SCAN ERROR (exit $CLAMAV_EXIT) — see $RESULTS_DIR/clamav.log"
  echo "[clamav] ── last 20 lines of clamav.log ──"
  tail -n 20 "$RESULTS_DIR/clamav.log" | sed 's/^/[clamav]   /'
  echo "[clamav] ── end ──"
  exit "$CLAMAV_EXIT"
fi

scan_ran clamav "$(grep -oE 'Scanned files: [0-9]+' "$RESULTS_DIR/clamav.log" | head -1 || echo 'files unknown')"
if [ "$SIG_STATE" = unverified ]; then
  echo "[clamav] PASS — no infections found (signature age UNVERIFIED — override in effect)"
else
  echo "[clamav] PASS — no infections found"
fi
exit 0
