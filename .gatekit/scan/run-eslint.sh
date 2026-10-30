#!/usr/bin/env bash
# run-eslint.sh — run each app's own `lint` script (it must start with eslint), with --max-warnings 0, and collect the results.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="${ESLINT_ROOT:-$PROJECT_ROOT}"
RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"
APPS="${ESLINT_APPS:-.}"
NPX="${ESLINT_NPX:-npx}"
LOG="$RESULTS_DIR/eslint.log"

# shellcheck source=scan-receipt.sh
. "$SCRIPT_DIR/scan-receipt.sh"

scan_begin eslint

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "[eslint] FAIL — jq is required. The scanner did not run."; exit 1
fi

if ! command -v "$NPX" >/dev/null 2>&1; then
  echo "[eslint] FAIL — '$NPX' not found on PATH. The scanner did not run."; exit 1
fi

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR/eslint.json" "$RESULTS_DIR"/eslint-*.json
: > "$LOG"

ran=0; failed=0; apps_json='[]'
for app in $APPS; do
  dir="$ROOT/$app"
  [ -f "$dir/package.json" ] || { say "[eslint] $app: no package.json — not an app dir here, skipped"; continue; }
  lint_script=$(jq -r '.scripts.lint // ""' "$dir/package.json")
  case "$lint_script" in
    eslint\ *|eslint) ;;
    "") say "[eslint] FAIL — $app: package.json has no lint script. The scanner did not run."; failed=1; continue ;;
    *)  say "[eslint] FAIL — $app: lint script does not start with eslint (\"$lint_script\"). The scanner did not run."; failed=1; continue ;;
  esac
  if [ ! -d "$dir/node_modules" ]; then
    say "[eslint] FAIL — $app: no node_modules; install before scanning (cd $app && npm ci). The scanner did not run."
    failed=1; continue
  fi
  # shellcheck disable=SC2206
  args=( ${lint_script#eslint} )
  raw="$RESULTS_DIR/eslint-$(printf '%s' "$app" | tr '/.' '__').json"
  say "[eslint] $app: eslint ${args[*]} --max-warnings 0 (format json)"
  (cd "$dir" && "$NPX" --no-install eslint "${args[@]}" --format json --max-warnings 0 > "$raw" 2>>"$LOG")
  rc=$?
  if [ "$rc" -ge 2 ] || ! jq -e 'type == "array"' "$raw" >/dev/null 2>&1; then
    say "[eslint] FAIL — $app: eslint exited $rc without a report (see $LOG). The scanner did not run."
    failed=1; continue
  fi
  ran=$((ran + 1))
  apps_json=$(jq -n --arg app "$app" --arg dir "$dir/" --slurpfile raw "$raw" --argjson apps "$apps_json" '
    $apps + [{
      app: $app,
      files: ($raw[0] | length),
      errors: ($raw[0] | map(.errorCount // 0) | add // 0),
      warnings: ($raw[0] | map(.warningCount // 0) | add // 0),
      messages: [ $raw[0][] | .filePath as $f | .messages[]
                  | { app: $app,
                      file: ($f | ltrimstr($dir)),
                      line: (.line // 0), column: (.column // 0),
                      rule: (.ruleId // "parse"),
                      severity: (if .severity == 2 then "error" else "warning" end),
                      message: (.message // "") } ] }]')
done

[ "$failed" -eq 0 ] || exit 1
if [ "$ran" -eq 0 ]; then
  say "[eslint] FAIL — no app dir under $ROOT (looked for: $APPS). The scanner did not run."
  exit 1
fi

jq -n --argjson apps "$apps_json" '
  { scanner: "eslint",
    policy: "every message blocks: both apps lint with --max-warnings 0",
    apps: $apps,
    blocking: [ $apps[].messages[] ] }' > "$RESULTS_DIR/eslint.json" 2>>"$LOG"

if ! jq -e '.blocking' "$RESULTS_DIR/eslint.json" >/dev/null 2>&1; then
  rm -f "$RESULTS_DIR/eslint.json"
  say "[eslint] FAIL — could not write the decision file (see $LOG). The scanner did not run."
  exit 1
fi

B=$(jq '.blocking | length' "$RESULTS_DIR/eslint.json")
say "[eslint] Results: $ran app(s) linted · $B message(s) ($(jq -r '[.apps[] | "\(.app): \(.errors) error(s) \(.warnings) warning(s) in \(.files) file(s)"] | join("; ")' "$RESULTS_DIR/eslint.json"))"
jq -r '.blocking[] | "  BLOCKING  \(.app)  \(.file):\(.line):\(.column)  \(.severity)  \(.rule)  \(.message)"' "$RESULTS_DIR/eslint.json" | tee -a "$LOG"

if [ "$B" -gt 0 ]; then
  say "[eslint] FAIL — $B message(s). Fix them; both apps run eslint with --max-warnings 0, so a warning is a failure by policy."
  exit 1
fi
scan_ran eslint "$ran app(s)"
say "[eslint] PASS — no messages"
exit 0
