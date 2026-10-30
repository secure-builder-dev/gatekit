#!/usr/bin/env bash
# scan-test-runner.sh — self-tests for the scanner scripts, using fake tools and the fixtures in ../fixtures. Never touches real scan results.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCAN_DIR/../.." && pwd)"
FIXTURE_DIR="$SCAN_DIR/fixtures"
# The fixtures are laid out as a backend/ and a frontend/ app.
export NPM_AUDIT_APPS="backend frontend" ESLINT_APPS="backend frontend" GATEKIT_APPS="backend frontend"

_LIVE_RESULTS="$PROJECT_ROOT/.gatekit/records/scan-latest"
[ -d "$_LIVE_RESULTS" ] || _LIVE_RESULTS=""
_live_manifest() {
  [ -n "$_LIVE_RESULTS" ] || return 1
  local m; m="$(find "$_LIVE_RESULTS" -type f 2>/dev/null | LC_ALL=C sort | xargs cksum 2>/dev/null)"
  [ -n "$m" ] || return 1
  printf '%s' "$m"
}
_LIVE_BEFORE="$(_live_manifest)" || _LIVE_BEFORE=""
SCAN_RESULTS_DIR="$(mktemp -d)"; export SCAN_RESULTS_DIR
trap 'rm -rf "$SCAN_RESULTS_DIR"' EXIT

PASS=0
FAIL=0
SKIP=0

DATE_SOON=$(date -u -d '+10 days' +%Y-%m-%d 2>/dev/null || date -u -v+10d +%Y-%m-%d)

_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
_skip() { echo "  SKIP: $1 — $2"; SKIP=$((SKIP + 1)); }

check_executable() {
  local name="$1" path="$2"
  if [[ -x "$path" ]]; then _pass "$name"; else _fail "$name" "not found or not executable: $path"; fi
}

check_makefile_target() {
  local target="$1"
  local mf="$PROJECT_ROOT/Makefile"
  if [[ -f "$mf" ]] && grep -qE "^$target[[:space:]]*(:|##)" "$mf"; then
    _pass "Makefile has target: $target"
  else
    _fail "Makefile has target: $target" "target not found in $mf"
  fi
}

echo ""
echo "=== Group 1: Script existence and permissions ==="
for script in run-hadolint.sh run-checkov.sh run-clamav.sh run-grype.sh run-trivy.sh run-npm-audit.sh run-eslint.sh pull-images.sh checkov-decide.sh generate-dispatch.sh; do
  check_executable "$script exists and is executable" "$SCAN_DIR/$script"
done

echo ""
echo "=== Group 2: gatekit wiring ==="
GK_MF="$PROJECT_ROOT/.gatekit/Makefile.gatekit"; GK_SCANS="$PROJECT_ROOT/.gatekit/scans.sh"
for target in gatekit-init scans patch gates-light gates-heavy; do
  grep -q "^$target:" "$GK_MF" && _pass "Makefile.gatekit has target: $target" || _fail "Makefile.gatekit has target: $target" "missing in $GK_MF"
done
for r in pull-images build-images run-hadolint run-checkov run-clamav run-grype run-trivy run-npm-audit run-eslint generate-dispatch; do
  grep -q "$r" "$GK_SCANS" && _pass "scans.sh runs $r" || _fail "scans.sh runs $r" "not called"
done
grep -q 'GATE_LINE_STAMP=1 bash "$S/gate-line.sh"' "$GK_SCANS" && _pass "scans.sh stamps the commit it scanned" || _fail "scans.sh stamps the commit it scanned" "no GATE_LINE_STAMP=1"
grep -q 'GATE_LINE_STAMP' "$PROJECT_ROOT/.gatekit/gate/run-gate.sh" && _fail "run-gate.sh does not stamp" "it sets GATE_LINE_STAMP" || _pass "run-gate.sh does not stamp (it only reads the verdict)"
[ "$(grep -n 'pull-images' "$GK_SCANS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'run-hadolint' "$GK_SCANS" | head -1 | cut -d: -f1)" ] \
  && _pass "scans.sh pulls scanner images first" || _fail "scans.sh pulls scanner images first" "pull comes after a scanner"
grep -q 'pull-images.sh.*|| true' "$GK_SCANS" && _fail "scans.sh does not swallow a failed image pull" "|| true on pull" || _pass "scans.sh does not swallow a failed image pull"

echo ""
echo "=== Group 3: Image scanners never silently skip ==="

no_silent_skip_test() {
  local script_name="$1"
  local path="$SCAN_DIR/$script_name"
  local output
  if [[ ! -x "$path" ]]; then
    _fail "$script_name never reports a skip" "script does not exist"
    return
  fi
  output=$(env -u BASE_IMAGE "$path" 2>&1 || true)
  if echo "$output" | grep -q "SKIPPED"; then
    _fail "$script_name never reports a skip" "printed SKIPPED: $(echo "$output" | grep SKIPPED | head -1)"
  else
    _pass "$script_name never reports a skip"
  fi
}

no_registry_auth_test() {
  local script_name="$1"
  local path="$SCAN_DIR/$script_name"
  if grep -qiE "docker login|podman login" "$path"; then
    _fail "$script_name carries no registry credentials" "found registry auth in a local-image scanner"
  else
    _pass "$script_name carries no registry credentials"
  fi
}

for img_script in run-grype.sh run-trivy.sh; do
  no_silent_skip_test "$img_script"
  no_registry_auth_test "$img_script"
done

bare_canary=$(mktemp -d); cp "$SCAN_DIR/run-grype.sh" "$bare_canary/run-grype.sh"
printf 'grype --output json some-image:tag\n' >> "$bare_canary/run-grype.sh"
canary_hit=$(grep -nE '(^|[^_[:alnum:]])(hadolint|checkov|clamscan|grype|trivy)[[:space:]]+[^)=]' \
  "$bare_canary/run-grype.sh" | grep -vE 'tool_|command -v|^[0-9]+:[[:space:]]*#|echo|install|NOT INSTALLED|scan_(begin|ran|none)[[:space:]]' || true)
if [ -n "$canary_hit" ]; then
  _pass "the bare-scanner-call guard still catches a planted bare call"
else
  _fail "the bare-scanner-call guard still catches a planted bare call" "a planted 'grype --output json' was not seen"
fi
rm -rf "$bare_canary"

echo ""
echo "=== Group 4: Dispatch generator routing ==="

run_dispatch_test() {
  local label="$1"
  local fixture_set="$2"
  local expect_dispatch="$3"      # "yes" | "no"
  local expect_poam="$4"          # "yes" | "no"
  local dispatch_contains="${5:-}"

  local gen="$SCAN_DIR/generate-dispatch.sh"
  if [[ ! -x "$gen" ]]; then
    _fail "Dispatch [$label]: generate-dispatch.sh runs without error" "script does not exist"
    [[ "$expect_dispatch" == "yes" ]] && _fail "Dispatch [$label]: dispatch.md written" "script does not exist"
    [[ "$expect_dispatch" == "no" ]]  && _fail "Dispatch [$label]: dispatch.md NOT written" "script does not exist"
    [[ "$expect_poam" == "yes" ]]     && _fail "Dispatch [$label]: poam-candidates.md written" "script does not exist"
    return
  fi

  local src_dir out_dir
  src_dir=$(mktemp -d)
  out_dir=$(mktemp -d)
  cp "$FIXTURE_DIR/$fixture_set/"* "$src_dir/"

  local gd_exit=0
  SCAN_RESULTS_DIR="$src_dir" OUTPUT_DIR="$out_dir" "$gen" >/dev/null 2>&1 || gd_exit=$?
  _pass "Dispatch [$label]: generate-dispatch.sh ran (exit $gd_exit)"

  if [[ "$expect_dispatch" == "yes" ]]; then
    if [[ -f "$out_dir/dispatch.md" ]]; then
      _pass "Dispatch [$label]: dispatch.md written"
      if [[ -n "$dispatch_contains" ]]; then
        if grep -q "$dispatch_contains" "$out_dir/dispatch.md"; then
          _pass "Dispatch [$label]: dispatch.md contains '$dispatch_contains'"
        else
          _fail "Dispatch [$label]: dispatch.md contains '$dispatch_contains'" "not found in dispatch.md"
        fi
      fi
    else
      _fail "Dispatch [$label]: dispatch.md written" "file not created in $out_dir"
      [[ -n "$dispatch_contains" ]] && _fail "Dispatch [$label]: dispatch.md contains '$dispatch_contains'" "dispatch.md missing"
    fi
  else
    if [[ ! -f "$out_dir/dispatch.md" ]]; then
      _pass "Dispatch [$label]: dispatch.md NOT written"
    else
      _fail "Dispatch [$label]: dispatch.md NOT written" "dispatch.md was incorrectly created"
    fi
  fi

  if [[ "$expect_poam" == "yes" ]]; then
    if [[ -f "$out_dir/poam-candidates.md" ]]; then
      _pass "Dispatch [$label]: poam-candidates.md written"
    else
      _fail "Dispatch [$label]: poam-candidates.md written" "file not created"
    fi
  fi

  rm -rf "$src_dir" "$out_dir"
}

run_dispatch_test "package-findings"  "package-findings"  "yes" "no"  "Package and lint fixes"
run_dispatch_test "infra-findings"   "infra-findings"   "yes" "no"  "Dockerfile / Helm / Terraform fixes"
run_dispatch_test "poam-only"        "poam-only"        "no"  "yes" ""
run_dispatch_test "clean"            "clean"            "no"  "no"  ""
run_dispatch_test "npm-audit-blocking" "npm-audit-blocking" "yes" "no" "GHSA-fixt-high-0001"
run_dispatch_test "eslint-findings"   "eslint-findings"   "yes" "no" "react-hooks/rules-of-hooks"
run_dispatch_test "checkov-null-severity" "checkov-null-severity" "yes" "no" "CKV_K8S_21"

echo ""
echo "=== Group 5: ClamAV EICAR detection ==="

# shellcheck source=../tool-runner.sh
. "$SCAN_DIR/tool-runner.sh"

if ! have_tool clamscan; then
  _skip "run-clamav.sh exits 1 on EICAR detection" "no clamscan and no Docker ($(scan_engine) engine)"
  _skip "run-clamav.sh prints INFECTION DETECTED on EICAR" "no clamscan and no Docker ($(scan_engine) engine)"
elif [[ ! -x "$SCAN_DIR/run-clamav.sh" ]]; then
  _fail "run-clamav.sh exits 1 on EICAR detection" "script does not exist"
  _fail "run-clamav.sh prints INFECTION DETECTED on EICAR" "script does not exist"
else
  eicar_dir=$(mktemp -d)
  printf 'X5O!P%%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
    > "$eicar_dir/eicar.com"
  eicar_results=$(mktemp -d)
  eicar_out=$(SCAN_DIR_OVERRIDE="$eicar_dir" SCAN_RESULTS_DIR="$eicar_results" CLAMAV_MAX_AGE_DAYS=36500 \
    "$SCAN_DIR/run-clamav.sh" 2>&1) && eicar_exit=0 || eicar_exit=$?
  rm -rf "$eicar_results"
  if [[ $eicar_exit -eq 1 ]]; then
    _pass "run-clamav.sh exits 1 on EICAR detection"
  elif [[ $eicar_exit -eq 0 ]]; then
    _fail "run-clamav.sh exits 1 on EICAR detection" "exit 0 — EICAR was not detected"
  else
    _fail "run-clamav.sh exits 1 on EICAR detection" \
      "exit $eicar_exit — the scanner failed to run, it did not scan and find nothing"
  fi
  if echo "$eicar_out" | grep -qi "INFECTION DETECTED"; then
    _pass "run-clamav.sh prints INFECTION DETECTED on EICAR"
  else
    _fail "run-clamav.sh prints INFECTION DETECTED on EICAR" "expected INFECTION DETECTED in: $eicar_out"
  fi
  rm -rf "$eicar_dir"
fi

echo ""
echo "=== Group 6: Container tool runner ==="

RUNNER="$SCAN_DIR/tool-runner.sh"
check_executable "tool-runner.sh exists" "$RUNNER"
if [[ -f "$SCAN_DIR/tool-versions.env" ]]; then
  _pass "tool-versions.env exists"
else
  _fail "tool-versions.env exists" "not found"
fi

engine_of() { ( export SCAN_ENGINE="$1"; . "$RUNNER" >/dev/null 2>&1; scan_engine ); }
for want in native container; do
  got=$(engine_of "$want" 2>/dev/null || echo ERROR)
  if [[ "$got" == "$want" ]]; then
    _pass "SCAN_ENGINE=$want resolves to $want"
  else
    _fail "SCAN_ENGINE=$want resolves to $want" "got '$got'"
  fi
done

for script in run-hadolint.sh run-checkov.sh run-clamav.sh run-grype.sh run-trivy.sh; do
  if grep -q 'tool-runner.sh' "$SCAN_DIR/$script"; then
    _pass "$script sources tool-runner.sh"
  else
    _fail "$script sources tool-runner.sh" "no reference found"
  fi
  if grep -qE '^if ! command -v (hadolint|checkov|clamscan|grype|trivy) ' "$SCAN_DIR/$script"; then
    _fail "$script has no host-binary gate" "still gates on 'command -v' for its scanner"
  else
    _pass "$script has no host-binary gate"
  fi
  bare=$(grep -nE '(^|[^_[:alnum:]])(hadolint|checkov|clamscan|grype|trivy)[[:space:]]+[^)=]' \
           "$SCAN_DIR/$script" | grep -vE 'tool_|command -v|^[0-9]+:[[:space:]]*#|echo|install|NOT INSTALLED|scan_(begin|ran|none)[[:space:]]' || true)
  if [[ -z "$bare" ]]; then
    _pass "$script invokes its scanner only through tool-runner"
  else
    _fail "$script invokes its scanner only through tool-runner" "bare call: $(echo "$bare" | head -1)"
  fi
done

unpinned=0
while IFS= read -r ref; do
  [[ "$ref" == *:* || "$ref" == *@sha256:* ]] || unpinned=$((unpinned + 1))
done < <( ( . "$RUNNER" >/dev/null 2>&1
            printf '%s\n' "$SCAN_IMAGE_HADOLINT" "$SCAN_IMAGE_CHECKOV" \
                           "$SCAN_IMAGE_CLAMAV" "$SCAN_IMAGE_GRYPE" "$SCAN_IMAGE_TRIVY" ) )
if [[ "$unpinned" -eq 0 ]]; then
  _pass "all five scanner images carry an explicit tag or digest"
else
  _fail "all five scanner images carry an explicit tag or digest" "$unpinned unpinned"
fi

clamav_ref=$( . "$RUNNER" >/dev/null 2>&1; printf '%s' "$SCAN_IMAGE_CLAMAV" )
if [[ "$clamav_ref" == *@sha256:* ]]; then
  _fail "ClamAV image is not digest-pinned" "digest pin freezes virus signatures: $clamav_ref"
else
  _pass "ClamAV image is not digest-pinned"
fi

clamav_tag="${clamav_ref##*:}"
if [[ "$clamav_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(_base)?$ ]]; then
  _fail "ClamAV image is on a moving tag" \
    "$clamav_ref is a patch tag — published once, never rebuilt, so its signatures never move"
else
  _pass "ClamAV image is on a moving tag"
fi

echo ""
platform_of() { ( export SCAN_PLATFORM_CLAMAV="$1"; . "$RUNNER" >/dev/null 2>&1; _tr_clamav_platform ); }

got=$(platform_of "linux/amd64" || true)
if [[ "$got" == "--platform linux/amd64" ]]; then
  _pass "ClamAV wrapper requests a platform when one is set"
else
  _fail "ClamAV wrapper requests a platform when one is set" "got '$got'"
fi

got=$(platform_of "" || true)
if [[ -z "$got" ]]; then
  _pass "ClamAV wrapper emits nothing when the platform override is empty"
else
  _fail "ClamAV wrapper emits nothing when the platform override is empty" "got '$got'"
fi

got=$( ( . "$RUNNER" >/dev/null 2>&1; printf '%s' "${SCAN_PLATFORM_CLAMAV:-}" ) )
if [[ -n "$got" ]]; then
  _pass "tool-versions.env sets a default ClamAV platform ($got)"
else
  _fail "tool-versions.env sets a default ClamAV platform" "SCAN_PLATFORM_CLAMAV is empty by default"
fi

clam_calls=$(grep -c '[$](_tr_clamav_platform)' "$RUNNER" || true)
if [[ "$clam_calls" -eq 2 ]]; then
  _pass "both ClamAV docker calls request the platform"
else
  _fail "both ClamAV docker calls request the platform" "found $clam_calls of 2"
fi

echo "=== Group 7: Gate verdict line ==="

GL="$SCAN_DIR/gate-line.sh"
check_executable "gate-line.sh exists" "$GL"

gate_verdict() {
  local label="$1" fixture="$2" expect="$3" extra="${4:-}"
  local dir out code
  dir=$(mktemp -d)
  cp "$FIXTURE_DIR/$fixture/"* "$dir/" 2>/dev/null
  SCAN_RESULTS_DIR="$dir" OUTPUT_DIR="$dir" "$SCAN_DIR/generate-dispatch.sh" >/dev/null 2>&1 || true
  out=$(SCAN_RESULTS_DIR="$dir" bash "$GL" 2>&1) && code=0 || code=1

  if echo "$out" | grep -q "Scan: $expect"; then
    _pass "Gate verdict [$label] = $expect"
  else
    _fail "Gate verdict [$label] = $expect" "got: $out"
  fi
  if [[ "$expect" == "PASS" && $code -ne 0 ]] || [[ "$expect" == "FAIL" && $code -eq 0 ]]; then
    _fail "Gate verdict [$label] exit code matches verdict" "verdict $expect but exit $code"
  else
    _pass "Gate verdict [$label] exit code matches verdict"
  fi
  if [[ -n "$extra" ]]; then
    if echo "$out" | grep -q "$extra"; then
      _pass "Gate verdict [$label] reports '$extra'"
    else
      _fail "Gate verdict [$label] reports '$extra'" "got: $out"
    fi
  fi
  rm -rf "$dir"
}

gate_verdict "clean"     "clean"          "PASS"
gate_verdict "fixable"   "infra-findings" "FAIL"

gate_verdict "poam only" "poam-only"      "PASS" "POAM candidate"

gate_verdict "npm audit blocking" "npm-audit-blocking" "FAIL" "1 fixable"

gate_verdict "eslint findings" "eslint-findings" "FAIL" "2 fixable"
gate_verdict "checkov unrated" "checkov-null-severity" "FAIL" "1 fixable"
gate_verdict "clean counts seven" "clean" "PASS" "7/7 scanners"

es_missing_dir=$(mktemp -d)
cp "$FIXTURE_DIR/clean/"* "$es_missing_dir/" 2>/dev/null
rm -f "$es_missing_dir/eslint.json"
es_ms_out=$(SCAN_RESULTS_DIR="$es_missing_dir" bash "$GL" 2>&1) || true
if echo "$es_ms_out" | grep -q "Scan: FAIL" && echo "$es_ms_out" | grep -q "eslint"; then
  _pass "Gate verdict: a missing eslint result is FAIL and is named"
else
  _fail "Gate verdict: a missing eslint result is FAIL and is named" "got: $es_ms_out"
fi
rm -rf "$es_missing_dir"

na_missing_dir=$(mktemp -d)
cp "$FIXTURE_DIR/clean/"* "$na_missing_dir/" 2>/dev/null
rm -f "$na_missing_dir/audit.json"
na_ms_out=$(SCAN_RESULTS_DIR="$na_missing_dir" bash "$GL" 2>&1) || true
if echo "$na_ms_out" | grep -q "Scan: FAIL" && echo "$na_ms_out" | grep -q "npm-audit"; then
  _pass "Gate verdict: a missing npm audit result is FAIL and is named"
else
  _fail "Gate verdict: a missing npm audit result is FAIL and is named" "got: $na_ms_out"
fi
rm -rf "$na_missing_dir"

missing_scanner_dir=$(mktemp -d)
cp "$FIXTURE_DIR/clean/"* "$missing_scanner_dir/" 2>/dev/null
rm -f "$missing_scanner_dir/trivy.json"
ms_out=$(SCAN_RESULTS_DIR="$missing_scanner_dir" bash "$GL" 2>&1) || true
if echo "$ms_out" | grep -q "Scan: FAIL" && echo "$ms_out" | grep -q "trivy"; then
  _pass "Gate verdict: a scanner that did not run is FAIL and is named"
else
  _fail "Gate verdict: a scanner that did not run is FAIL and is named" "got: $ms_out"
fi
rm -rf "$missing_scanner_dir"

eicar_dir=$(mktemp -d)
cp "$FIXTURE_DIR/clean/"* "$eicar_dir/" 2>/dev/null
printf '/src/nasty.bin: Eicar-Test-Signature FOUND\n\n----------- SCAN SUMMARY -----------\nInfected files: 1\n' \
  > "$eicar_dir/clamav.log"
SCAN_RESULTS_DIR="$eicar_dir" OUTPUT_DIR="$eicar_dir" "$SCAN_DIR/generate-dispatch.sh" >/dev/null 2>&1 || true
mw_out=$(SCAN_RESULTS_DIR="$eicar_dir" bash "$GL" 2>&1) || true
if echo "$mw_out" | grep -q "Scan: FAIL" && echo "$mw_out" | grep -q "MALWARE DETECTED"; then
  _pass "Gate verdict: a ClamAV hit is FAIL and says MALWARE DETECTED"
else
  _fail "Gate verdict: a ClamAV hit is FAIL and says MALWARE DETECTED" "got: $mw_out"
fi
rm -rf "$eicar_dir"

echo ""
echo "=== Group 9: npm audit runner (fake npm, real policy) ==="

NA="$SCAN_DIR/run-npm-audit.sh"
check_executable "run-npm-audit.sh exists and is executable" "$NA"

na_fixture() {   # na_fixture <canned stdout for npm>  → prints the fixture root
  local root; root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/backend" "$root/frontend" "$root/results"
  printf '{}\n' > "$root/backend/package-lock.json"
  printf '{}\n' > "$root/frontend/package-lock.json"
  printf '%s' "$1" > "$root/canned"
  cat > "$root/bin/npm" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_CANNED"
exit 1
FAKE
  chmod +x "$root/bin/npm"
  printf '%s' "$root"
}
na_run() {   # na_run <root> [allowlist file] → sets NA_RC (exit code) and NA_OUT (output).
  local root="$1" allow="${2:-$1/no-such-allowlist.yaml}"
  NA_RC=0
  NA_OUT=$(FAKE_CANNED="$root/canned" PATH="$root/bin:$PATH" NPM_AUDIT_ROOT="$root" \
           SCAN_RESULTS_DIR="$root/results" NPM_AUDIT_ALLOWLIST="$allow" bash "$NA" 2>&1) || NA_RC=$?
}
NA_HIGH='{"vulnerabilities":{"vite":{"name":"vite","severity":"high","isDirect":true,"via":[{"source":1,"name":"vite","dependency":"vite","title":"fixture high","url":"https://github.com/advisories/GHSA-fake-high-0001","severity":"high","range":"<=6.4.2"}],"effects":[],"range":"<=6.4.2","nodes":["node_modules/vite"],"fixAvailable":{"name":"vite","version":"8.3.0","isSemVerMajor":true}}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}'
NA_MOD='{"vulnerabilities":{"esbuild":{"name":"esbuild","severity":"moderate","isDirect":false,"via":[{"source":2,"name":"esbuild","dependency":"esbuild","title":"fixture moderate","url":"https://github.com/advisories/GHSA-fake-mod-0002","severity":"moderate","range":"<=0.24.2"}],"effects":["vite"],"range":"<=0.24.2","nodes":["node_modules/esbuild"],"fixAvailable":true},"vite":{"name":"vite","severity":"moderate","isDirect":true,"via":["esbuild"],"effects":[],"range":"<=6.4.2","nodes":["node_modules/vite"],"fixAvailable":true}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":2,"high":0,"critical":0,"total":2}}}'
NA_CLEAN='{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}'

root=$(na_fixture "$NA_CLEAN"); na_run "$root"; rc=$NA_RC
[[ "$rc" == 0 ]] && _pass "npm-audit: clean report exits 0" || _fail "npm-audit: clean report exits 0" "exit $rc: $NA_OUT"
[[ -s "$root/results/audit.json" && "$(jq '.blocking | length' "$root/results/audit.json")" == 0 ]] \
  && _pass "npm-audit: clean report writes audit.json with no blocking entries" \
  || _fail "npm-audit: clean report writes audit.json with no blocking entries" "missing or non-empty"
rm -rf "$root"

root=$(na_fixture "$NA_HIGH"); na_run "$root"; rc=$NA_RC
[[ "$rc" == 1 ]] && _pass "npm-audit: a High with no allowlist entry exits 1" || _fail "npm-audit: a High with no allowlist entry exits 1" "exit $rc"
echo "$NA_OUT" | grep -q "BLOCKING.*GHSA-fake-high-0001" && _pass "npm-audit: the blocking advisory is named" || _fail "npm-audit: the blocking advisory is named" "got: $NA_OUT"
[[ "$(jq '.blocking | length' "$root/results/audit.json")" == 2 ]] \
  && _pass "npm-audit: blocking is counted once per app" \
  || _fail "npm-audit: blocking is counted once per app" "got $(jq '.blocking | length' "$root/results/audit.json")"
printf 'entries:\n  - id: GHSA-fake-high-0001\n    package: vite\n    reason: fixture\n    owner: test\n    expires: %s\n' "$DATE_SOON" > "$root/allow.yaml"
na_run "$root" "$root/allow.yaml"; rc=$NA_RC
[[ "$rc" == 0 ]] && _pass "npm-audit: an unexpired allowlist entry lifts the block" || _fail "npm-audit: an unexpired allowlist entry lifts the block" "exit $rc: $NA_OUT"
[[ "$(jq '.allowlisted | length' "$root/results/audit.json")" == 2 ]] \
  && _pass "npm-audit: the allowlisted advisory is recorded as allowlisted" \
  || _fail "npm-audit: the allowlisted advisory is recorded as allowlisted" "got $(jq '.allowlisted | length' "$root/results/audit.json")"
sed -i.bak "s/$DATE_SOON/2000-01-01/" "$root/allow.yaml"
na_run "$root" "$root/allow.yaml"; rc=$NA_RC
[[ "$rc" == 1 ]] && _pass "npm-audit: an expired allowlist entry suppresses nothing" || _fail "npm-audit: an expired allowlist entry suppresses nothing" "exit $rc"
echo "$NA_OUT" | grep -qi "expired" && _pass "npm-audit: an expired entry is called out" || _fail "npm-audit: an expired entry is called out" "got: $NA_OUT"
rm -rf "$root"

root=$(na_fixture "$NA_MOD"); na_run "$root"; rc=$NA_RC
[[ "$rc" == 0 ]] && _pass "npm-audit: Moderate alone exits 0" || _fail "npm-audit: Moderate alone exits 0" "exit $rc: $NA_OUT"
echo "$NA_OUT" | grep -q "reported.*GHSA-fake-mod-0002" && _pass "npm-audit: Moderate is reported by id" || _fail "npm-audit: Moderate is reported by id" "got: $NA_OUT"
rm -rf "$root"

root=$(na_fixture "npm ERR! network request to https://registry failed"); na_run "$root"; rc=$NA_RC
[[ "$rc" == 1 ]] && _pass "npm-audit: an unparseable report exits 1" || _fail "npm-audit: an unparseable report exits 1" "exit $rc"
echo "$NA_OUT" | grep -q "did not run" && _pass "npm-audit: …and says the scanner did not run" || _fail "npm-audit: …and says the scanner did not run" "got: $NA_OUT"
[[ ! -f "$root/results/audit.json" ]] && _pass "npm-audit: …and writes no audit.json" || _fail "npm-audit: …and writes no audit.json" "audit.json exists"
rm -rf "$root"

root=$(na_fixture "$NA_CLEAN"); rm -f "$root/backend/package-lock.json" "$root/frontend/package-lock.json"; na_run "$root"; rc=$NA_RC
[[ "$rc" == 1 ]] && _pass "npm-audit: no lockfile anywhere exits 1" || _fail "npm-audit: no lockfile anywhere exits 1" "exit $rc"
rm -rf "$root"

na_calls_fix() { grep -vE '^[[:space:]]*#' "$1" | grep -qE 'audit[[:space:]]+fix'; }
if na_calls_fix "$NA"; then
  _fail "npm-audit: runner never calls npm audit fix" "found an audit fix call outside a comment"
else
  _pass "npm-audit: runner never calls npm audit fix"
fi
na_canary=$(mktemp); { cat "$NA"; echo 'npm audit fix'; } > "$na_canary"
if na_calls_fix "$na_canary"; then
  _pass "npm-audit: …and that check detects one when it is there"
else
  _fail "npm-audit: …and that check detects one when it is there" "a planted 'npm audit fix' was not seen"
fi
rm -f "$na_canary"

echo ""
echo "=== Group 10: eslint runner (fake npx, real policy) ==="

ES="$SCAN_DIR/run-eslint.sh"
check_executable "run-eslint.sh exists and is executable" "$ES"

es_fixture() {   # es_fixture <canned stdout for npx> <npx exit code> → prints the fixture root
  local root; root=$(mktemp -d)
  mkdir -p "$root/bin" "$root/backend/node_modules" "$root/frontend/node_modules" "$root/results"
  printf '{"scripts":{"lint":"eslint src --ext .ts --max-warnings 0"}}\n' > "$root/backend/package.json"
  printf '{"scripts":{"lint":"eslint . --max-warnings 0"}}\n' > "$root/frontend/package.json"
  printf '%s' "$1" > "$root/canned"; printf '%s' "$2" > "$root/canned.rc"
  cat > "$root/bin/npx" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_CANNED"
exit "$(cat "$FAKE_CANNED.rc")"
FAKE
  chmod +x "$root/bin/npx"
  printf '%s' "$root"
}
es_run() {   # es_run <root> → sets ES_RC and ES_OUT (no command substitution: a subshell would lose them)
  local root="$1"
  ES_RC=0
  ES_OUT=$(FAKE_CANNED="$root/canned" PATH="$root/bin:$PATH" ESLINT_ROOT="$root" \
           SCAN_RESULTS_DIR="$root/results" bash "$ES" 2>&1) || ES_RC=$?
}
ES_CLEAN='[{"filePath":"/x/src/a.ts","messages":[],"errorCount":0,"warningCount":0}]'
ES_ERR='[{"filePath":"/x/src/a.ts","messages":[{"ruleId":"no-undef","severity":2,"message":"fixture: foo is not defined","line":4,"column":3}],"errorCount":1,"warningCount":0}]'
ES_WARN='[{"filePath":"/x/src/a.ts","messages":[{"ruleId":"no-unused-vars","severity":1,"message":"fixture: x is defined but never used","line":9,"column":1}],"errorCount":0,"warningCount":1}]'

root=$(es_fixture "$ES_CLEAN" 0); es_run "$root"
[[ "$ES_RC" == 0 ]] && _pass "eslint: clean report exits 0" || _fail "eslint: clean report exits 0" "exit $ES_RC: $ES_OUT"
[[ -s "$root/results/eslint.json" && "$(jq '.blocking | length' "$root/results/eslint.json")" == 0 ]] \
  && _pass "eslint: clean report writes eslint.json with no blocking entries" \
  || _fail "eslint: clean report writes eslint.json with no blocking entries" "missing or non-empty"
rm -rf "$root"

root=$(es_fixture "$ES_ERR" 1); es_run "$root"
[[ "$ES_RC" == 1 ]] && _pass "eslint: an error exits 1" || _fail "eslint: an error exits 1" "exit $ES_RC"
echo "$ES_OUT" | grep -q "BLOCKING.*no-undef" && _pass "eslint: the message is named by rule" || _fail "eslint: the message is named by rule" "got: $ES_OUT"
rm -rf "$root"

root=$(es_fixture "$ES_WARN" 1); es_run "$root"
[[ "$ES_RC" == 1 ]] && _pass "eslint: a warning alone exits 1 (max-warnings 0)" || _fail "eslint: a warning alone exits 1 (max-warnings 0)" "exit $ES_RC"
rm -rf "$root"

root=$(es_fixture "Oops! Something went wrong! :(" 2); es_run "$root"
[[ "$ES_RC" == 1 ]] && _pass "eslint: a crash (exit 2) exits 1" || _fail "eslint: a crash (exit 2) exits 1" "exit $ES_RC"
echo "$ES_OUT" | grep -q "did not run" && _pass "eslint: …and says the scanner did not run" || _fail "eslint: …and says the scanner did not run" "got: $ES_OUT"
[[ ! -f "$root/results/eslint.json" ]] && _pass "eslint: …and writes no eslint.json" || _fail "eslint: …and writes no eslint.json" "eslint.json exists"
rm -rf "$root"

root=$(es_fixture "$ES_CLEAN" 0); rm -rf "$root/frontend/node_modules"; es_run "$root"
[[ "$ES_RC" == 1 ]] && _pass "eslint: an app without node_modules fails rather than skips" || _fail "eslint: an app without node_modules fails rather than skips" "exit $ES_RC"
echo "$ES_OUT" | grep -q "SKIPPED" && _fail "eslint: never prints SKIPPED" "printed SKIPPED" || _pass "eslint: never prints SKIPPED"
rm -rf "$root"

echo ""
echo "=== Group 11: hadolint honours .hadolint.yaml ==="

if ! have_tool hadolint; then
  _skip "hadolint config: ignored rules are absent" "no hadolint and no Docker ($(scan_engine) engine)"
else
  hl_dir=$(mktemp -d)
  printf 'FROM alpine:latest\nRUN apk add curl\nRUN apk add --no-cache git\nMAINTAINER nobody\n' > "$hl_dir/Dockerfile"
  hl_out=$(cd "$PROJECT_ROOT" && tool_hadolint --config .gatekit/scan/hadolint.yaml --format json "$(realpath --relative-to="$PROJECT_ROOT" "$hl_dir" 2>/dev/null || echo "$hl_dir")/Dockerfile" 2>/dev/null) || true
  if ! printf '%s' "$hl_out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    mkdir -p "$PROJECT_ROOT/.hadolint-selftest"
    cp "$hl_dir/Dockerfile" "$PROJECT_ROOT/.hadolint-selftest/Dockerfile"
    hl_out=$(cd "$PROJECT_ROOT" && tool_hadolint --config .gatekit/scan/hadolint.yaml --format json .hadolint-selftest/Dockerfile 2>/dev/null) || true
    rm -rf "$PROJECT_ROOT/.hadolint-selftest"
  fi
  hl_codes=$(printf '%s' "$hl_out" | jq -r '.[].code' 2>/dev/null | sort -u | tr '\n' ' ')
  case " $hl_codes " in
    *" DL3018 "*) _pass "hadolint config: strict by default — DL3018 (unpinned apk) is reported" ;;
    *)            _fail "hadolint config: strict by default — DL3018 (unpinned apk) is reported" "codes seen: '$hl_codes'" ;;
  esac
  case " $hl_codes " in
    *" DL3007 "*) _pass "hadolint config: strict by default — DL3007 (:latest base) is reported" ;;
    *)            _fail "hadolint config: strict by default — DL3007 (:latest base) is reported" "codes seen: '$hl_codes'" ;;
  esac
  case " $hl_codes " in
    *" DL4000 "*) _pass "hadolint config: an unlisted rule (DL4000 MAINTAINER) is still reported" ;;
    *)            _fail "hadolint config: an unlisted rule (DL4000 MAINTAINER) is still reported" "codes seen: '$hl_codes' — did hadolint run at all?" ;;
  esac
  rm -rf "$hl_dir"
fi

echo ""
echo "=== Group 12: a scan cannot be green without scanning ==="

PI="$SCAN_DIR/pull-images.sh"
pi_root=$(mktemp -d); mkdir -p "$pi_root/bin"
cat > "$pi_root/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  pull) echo "$*" >> "$FAKE_PULLS"; [ "${FAKE_PULL_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$pi_root/bin/docker"
pi_rc=0; pi_out=$(FAKE_PULLS="$pi_root/pulls" PATH="$pi_root/bin:$PATH" SCAN_ENGINE=container bash "$PI" 2>&1) || pi_rc=$?
[[ "$pi_rc" == 0 ]] && _pass "pull-images: exits 0 when every pull succeeds" || _fail "pull-images: exits 0 when every pull succeeds" "exit $pi_rc: $pi_out"
[[ "$(wc -l < "$pi_root/pulls" | tr -d ' ')" == 5 ]] && _pass "pull-images: pulls all five scanner images" || _fail "pull-images: pulls all five scanner images" "$(cat "$pi_root/pulls")"
grep -q -- '--platform linux/amd64.*clamav' "$pi_root/pulls" && _pass "pull-images: ClamAV is pulled for its platform" || _fail "pull-images: ClamAV is pulled for its platform" "$(grep clamav "$pi_root/pulls")"
rm -f "$pi_root/pulls"
pi_rc=0; pi_out=$(FAKE_PULLS="$pi_root/pulls" FAKE_PULL_FAIL=1 PATH="$pi_root/bin:$PATH" SCAN_ENGINE=container bash "$PI" 2>&1) || pi_rc=$?
[[ "$pi_rc" == 1 ]] && _pass "pull-images: a failed pull exits 1" || _fail "pull-images: a failed pull exits 1" "exit $pi_rc"
pi_rc=0; pi_out=$(SCAN_ENGINE=native bash "$PI" 2>&1) || pi_rc=$?
[[ "$pi_rc" == 0 ]] && _pass "pull-images: native engine has nothing to pull and exits 0" || _fail "pull-images: native engine has nothing to pull and exits 0" "exit $pi_rc: $pi_out"
rm -rf "$pi_root"


echo ""
echo "=== Group 13: checkov decides on every failed check ==="

CD="$SCAN_DIR/checkov-decide.sh"
check_executable "checkov-decide.sh exists and is executable" "$CD"
cd_fixture() { local d; d=$(mktemp -d); cp "$FIXTURE_DIR/checkov-null-severity/checkov.json" "$d/checkov.json"; printf '%s' "$d"; }
cd_run() {   # cd_run <dir> [justification file] → CD_RC, CD_OUT
  local d="$1" j="${2:-$1/no-such-file.yaml}"; CD_RC=0
  CD_OUT=$(CHECKOV_JUSTIFICATIONS="$j" bash "$CD" "$d/checkov.json" 2>&1) || CD_RC=$?
}
cd_just() {   # cd_just <dir> <path glob> <expires>
  printf 'entries:\n  - check_id: CKV_K8S_21\n    path: %s\n    reason: fixture\n    owner: test\n    expires: %s\n' "$2" "$3" > "$1/j.yaml"
}

d=$(cd_fixture); cd_run "$d"
[[ "$CD_RC" == 1 ]] && _pass "checkov-decide: an unrated failed check with no justification exits 1" || _fail "checkov-decide: an unrated failed check with no justification exits 1" "exit $CD_RC: $CD_OUT"
echo "$CD_OUT" | grep -q "BLOCKING.*CKV_K8S_21" && _pass "checkov-decide: the blocking check is named" || _fail "checkov-decide: the blocking check is named" "got: $CD_OUT"
rm -rf "$d"

d=$(cd_fixture); cd_just "$d" '/fixture/templates/*.yaml' "$DATE_SOON"; cd_run "$d" "$d/j.yaml"
[[ "$CD_RC" == 0 ]] && _pass "checkov-decide: a matching unexpired justification exits 0" || _fail "checkov-decide: a matching unexpired justification exits 0" "exit $CD_RC: $CD_OUT"
[[ "$(jq '.results.justified_checks | length' "$d/checkov.json")" == 1 && "$(jq '.results.failed_checks | length' "$d/checkov.json")" == 0 ]] \
  && _pass "checkov-decide: the justified check moves out of failed_checks" \
  || _fail "checkov-decide: the justified check moves out of failed_checks" "$(jq -c '.summary' "$d/checkov.json")"
rm -rf "$d"

d=$(cd_fixture); cd_just "$d" '/other/templates/*.yaml' "$DATE_SOON"; cd_run "$d" "$d/j.yaml"
[[ "$CD_RC" == 1 ]] && _pass "checkov-decide: a justification for another path does not apply" || _fail "checkov-decide: a justification for another path does not apply" "exit $CD_RC"
rm -rf "$d"

d=$(cd_fixture); cd_just "$d" '/fixture/templates/*.yaml' 2000-01-01; cd_run "$d" "$d/j.yaml"
[[ "$CD_RC" == 1 ]] && _pass "checkov-decide: an expired justification justifies nothing" || _fail "checkov-decide: an expired justification justifies nothing" "exit $CD_RC"
echo "$CD_OUT" | grep -qi "expired" && _pass "checkov-decide: the expired entry is called out" || _fail "checkov-decide: the expired entry is called out" "got: $CD_OUT"
rm -rf "$d"

d=$(mktemp -d); printf 'not json' > "$d/checkov.json"; cd_run "$d"
[[ "$CD_RC" == 1 ]] && _pass "checkov-decide: unreadable results exit 1" || _fail "checkov-decide: unreadable results exit 1" "exit $CD_RC"
rm -rf "$d"

grep -q 'checkov-decide.sh' "$SCAN_DIR/run-checkov.sh" && _pass "run-checkov.sh calls checkov-decide.sh" || _fail "run-checkov.sh calls checkov-decide.sh" "no call found"
grep -qE 'severity == "HIGH"' "$SCAN_DIR/run-checkov.sh" && _fail "run-checkov.sh no longer decides on severity" "HIGH/CRITICAL filter still present" || _pass "run-checkov.sh no longer decides on severity"

echo ""
echo "=== Group 14: an unreadable result is not a clean result ==="

polluted_case() {   # polluted_case <label> <result file> <how to break it: prepend|truncate>
  local label="$1" file="$2" how="$3" dir out rc=0
  dir=$(mktemp -d); cp "$FIXTURE_DIR/clean/"* "$dir/" 2>/dev/null
  case "$how" in
    prepend) { printf 'Unable to find image locally\nlatest: Pulling from a/b\n9621f1afde84: Pulling fs layer\n'; cat "$FIXTURE_DIR/clean/$file"; } > "$dir/$file" ;;
    truncate) printf '\n----------- SCAN SUMMARY -----------\nKnown viruses: 3628071\n' > "$dir/$file" ;;
  esac
  out=$(SCAN_RESULTS_DIR="$dir" bash "$GL" 2>&1) || rc=$?
  if echo "$out" | grep -q "Scan: FAIL" && echo "$out" | grep -q "$label" && [ "$rc" -ne 0 ]; then
    _pass "unreadable $file → FAIL, $label named, rc $rc"
  else
    _fail "unreadable $file → FAIL, $label named" "rc $rc · got: $out"
  fi
  rm -rf "$dir"
}
polluted_case hadolint  hadolint.json prepend
polluted_case checkov   checkov.json  prepend
polluted_case grype     grype.json    prepend
polluted_case trivy     trivy.json    prepend
polluted_case npm-audit audit.json    prepend
polluted_case eslint    eslint.json   prepend
polluted_case clamav    clamav.log    truncate

cj_dir=$(mktemp -d); printf 'Pulling from a/b\n[]\n' > "$cj_dir/hadolint.json"
( . "$SCAN_DIR/tool-runner.sh" >/dev/null 2>&1; count_json "$cj_dir/hadolint.json" 'length' hadolint ) >/dev/null 2>&1
if [[ ! -f "$cj_dir/hadolint.json" && -f "$cj_dir/hadolint.json.unparseable" ]]; then
  _pass "count_json moves an unparseable result aside and keeps it"
else
  _fail "count_json moves an unparseable result aside and keeps it" "$(ls "$cj_dir")"
fi
rm -rf "$cj_dir"

st_dir=$(mktemp -d); cp "$FIXTURE_DIR/clean/"* "$st_dir/" 2>/dev/null
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef PASS 2026-01-01T00:00:00Z\n' > "$st_dir/.scan-stamp"
SCAN_RESULTS_DIR="$st_dir" bash "$GL" >/dev/null 2>&1 || true
if grep -q '^deadbeef' "$st_dir/.scan-stamp"; then
  _pass "gate-line leaves the stamp alone when it is only reading"
else
  _fail "gate-line leaves the stamp alone when it is only reading" "stamp now: $(cat "$st_dir/.scan-stamp")"
fi
GATE_LINE_STAMP=1 SCAN_RESULTS_DIR="$st_dir" bash "$GL" >/dev/null 2>&1 || true
if ! grep -q '^deadbeef' "$st_dir/.scan-stamp"; then
  _pass "…and writes it when the caller actually scanned"
else
  _fail "…and writes it when the caller actually scanned" "stamp unchanged: $(cat "$st_dir/.scan-stamp")"
fi
rm -rf "$st_dir"

root=$(na_fixture "$NA_HIGH")
for pair in "2999-13-45:not a real date" "soon:not a date at all"; do
  d="${pair%%:*}"; why="${pair#*:}"
  printf 'entries:\n  - id: GHSA-fake-high-0001\n    package: vite\n    reason: fixture\n    owner: test\n    expires: %s\n' "$d" > "$root/allow.yaml"
  na_run "$root" "$root/allow.yaml"; rc=$NA_RC
  [[ "$rc" == 1 ]] && _pass "npm-audit: an expiry $why suppresses nothing" || _fail "npm-audit: an expiry $why suppresses nothing" "exit $rc"
done
printf 'entries:\n  - id: GHSA-fake-high-0001\n    package: vite\n    reason: fixture\n    owner: test\n    expires: %s\n' "$DATE_SOON" > "$root/allow.yaml"
na_run "$root" "$root/allow.yaml"; rc=$NA_RC
[[ "$rc" == 0 ]] && _pass "npm-audit: a readable future date still lifts the block" || _fail "npm-audit: a readable future date still lifts the block" "exit $rc: $NA_OUT"
rm -rf "$root"

d=$(cd_fixture)
printf 'entries:\n  - check_id: CKV_K8S_21\n    path: /fixture/templates/*.yaml\n    reason: fixture\n    owner: test\n    expires: soon\n' > "$d/j.yaml"
cd_run "$d" "$d/j.yaml"
[[ "$CD_RC" == 1 ]] && _pass "checkov: an expiry it cannot read justifies nothing" || _fail "checkov: an expiry it cannot read justifies nothing" "exit $CD_RC"
printf 'entries:\n  - check_id: CKV_K8S_21\n    path: /fixture/templates/*.yaml\n    reason: fixture\n    owner: test\n    expires: %s\n' "$DATE_SOON" > "$d/j.yaml"
cd_run "$d" "$d/j.yaml"
[[ "$CD_RC" == 0 ]] && _pass "checkov: a readable future date still justifies" || _fail "checkov: a readable future date still justifies" "exit $CD_RC: $CD_OUT"
rm -rf "$d"

echo ""
echo "=== Group 15: a scanner that examined nothing is not a scanner that ran ==="

SR="$SCAN_DIR/scan-receipt.sh"
check_executable "scan-receipt.sh exists and is executable" "$SR"

receipt_case() {   # receipt_case <scanner name>
  local name="$1" dir out rc=0
  dir=$(mktemp -d); cp "$FIXTURE_DIR/clean/"* "$dir/" 2>/dev/null
  grep -v "^${name} " "$dir/scanners-ran" > "$dir/scanners-ran.tmp" 2>/dev/null || : > "$dir/scanners-ran.tmp"
  mv "$dir/scanners-ran.tmp" "$dir/scanners-ran"
  out=$(SCAN_RESULTS_DIR="$dir" bash "$GL" 2>&1) || rc=$?
  if echo "$out" | grep -q "Scan: FAIL" && echo "$out" | grep -q "did not run:.*$name" && [ "$rc" -ne 0 ]; then
    _pass "no receipt from $name → FAIL, named, rc $rc (its result file is present and valid)"
  else
    _fail "no receipt from $name → FAIL, named" "rc $rc · got: $out"
  fi
  rm -rf "$dir"
}
for n in hadolint checkov clamav grype trivy npm-audit eslint; do receipt_case "$n"; done

dir=$(mktemp -d); cp "$FIXTURE_DIR/clean/"* "$dir/" 2>/dev/null
sed 's/^hadolint ran .*/hadolint none no Dockerfiles under backend\/ or frontend\//' "$dir/scanners-ran" > "$dir/sr.tmp" && mv "$dir/sr.tmp" "$dir/scanners-ran"
out=$(SCAN_RESULTS_DIR="$dir" bash "$GL" 2>&1); rc=$?
if echo "$out" | grep -q "Scan: PASS" && echo "$out" | grep -q "7/7" && echo "$out" | grep -q "nothing in scope: hadolint" && [ "$rc" -eq 0 ]; then
  _pass "a declared empty scope counts as ran and is named in the verdict"
else
  _fail "a declared empty scope counts as ran and is named in the verdict" "rc $rc · got: $out"
fi
rm -rf "$dir"

dir=$(mktemp -d)
( export SCAN_RECEIPT_DIR="$dir"; . "$SR"
  scan_ran grype "2 image(s)"; scan_ran trivy "2 image(s)"
  scan_begin grype )   # a new run starts; it has not earned a receipt yet
if [ "$(SCAN_RECEIPT_DIR="$dir" bash -c ". $SR; scan_receipt_kind grype")" = "" ] \
   && [ "$(SCAN_RECEIPT_DIR="$dir" bash -c ". $SR; scan_receipt_kind trivy")" = "ran" ]; then
  _pass "scan_begin drops only this scanner's stale receipt"
else
  _fail "scan_begin drops only this scanner's stale receipt" "$(cat "$dir/scanners-ran" 2>/dev/null)"
fi
rm -rf "$dir"

for pair in "run-hadolint.sh:hadolint" "run-checkov.sh:checkov" "run-clamav.sh:clamav" \
            "run-grype.sh:grype" "run-trivy.sh:trivy" "run-npm-audit.sh:npm-audit" "run-eslint.sh:eslint"; do
  f="$SCAN_DIR/${pair%%:*}"; n="${pair#*:}"
  if grep -q "scan_begin $n" "$f"; then _pass "${pair%%:*} clears its receipt on entry"
  else _fail "${pair%%:*} clears its receipt on entry" "no scan_begin"; fi
  if grep -qE "scan_(ran|none) $n" "$f"; then _pass "${pair%%:*} claims a receipt"
  else _fail "${pair%%:*} claims a receipt" "no scan_ran/scan_none"; fi
done

for pair in "run-eslint.sh:eslint:ESLINT_NPX" "run-npm-audit.sh:npm-audit:NPM_AUDIT_NPM"; do
  f="${pair%%:*}"; rest="${pair#*:}"; n="${rest%%:*}"; var="${rest#*:}"
  dir=$(mktemp -d)
  printf '%s ran 2 app(s)\ngrype ran 2 image(s)\n' "$n" > "$dir/scanners-ran"
  env "$var=definitely-not-on-this-path" SCAN_TRACK=web SCAN_RESULTS_DIR="$dir" bash "$SCAN_DIR/$f" >/dev/null 2>&1
  e_rc=$?
  e_self=$(SCAN_RECEIPT_DIR="$dir" bash -c ". $SR; scan_receipt_kind $n")
  e_other=$(SCAN_RECEIPT_DIR="$dir" bash -c ". $SR; scan_receipt_kind grype")
  if [ "$e_rc" -ne 0 ] && [ -z "$e_self" ] && [ "$e_other" = ran ]; then
    _pass "$f bailing out early drops its own stale receipt and leaves others alone"
  else
    _fail "$f bailing out early drops its own stale receipt and leaves others alone" \
      "rc $e_rc · own '$e_self' · other '$e_other'"
  fi
  rm -rf "$dir"
done

for pair in "run-hadolint.sh:hadolint" "run-checkov.sh:checkov" "run-clamav.sh:clamav" \
            "run-grype.sh:grype" "run-trivy.sh:trivy" "run-npm-audit.sh:npm-audit" "run-eslint.sh:eslint"; do
  f="$SCAN_DIR/${pair%%:*}"
  b_line=$(grep -n '^scan_begin' "$f" | head -1 | cut -d: -f1)
  early=$(awk -v b="${b_line:-0}" 'NR<b && $0 !~ /^[[:space:]]*#/ && /exit[[:space:]]+[0-9]/ {c++} END{print c+0}' "$f")
  if [ -n "$b_line" ] && [ "$early" -eq 0 ]; then
    _pass "${pair%%:*} clears its receipt before any exit path"
  else
    _fail "${pair%%:*} clears its receipt before any exit path" "scan_begin at line ${b_line:-none}, $early exit(s) above it"
  fi
done

if ! have_tool grype || ! command -v docker >/dev/null 2>&1; then
  _skip "grype scanning nothing leaves no receipt and no empty result" "docker unavailable"
else
  dir=$(mktemp -d); cp "$FIXTURE_DIR/clean/"* "$dir/" 2>/dev/null
  printf '{"matches":[{"vulnerability":{"id":"CVE-FIXTURE-1","severity":"High"},"artifact":{"name":"x","version":"1","type":"apk"}}]}\n' > "$dir/grype.json"
  SCAN_TRACK=web SCAN_RESULTS_DIR="$dir" SCAN_IMAGES="does-not-exist-fixture:nope" bash "$SCAN_DIR/run-grype.sh" >/dev/null 2>&1
  g_rc=$?
  g_kind=$(SCAN_RECEIPT_DIR="$dir" bash -c ". $SR; scan_receipt_kind grype")
  g_matches=$(jq '.matches | length' "$dir/grype.json" 2>/dev/null || echo ERR)
  g_out=$(SCAN_RESULTS_DIR="$dir" bash "$GL" 2>&1) || true
  [ "$g_rc" -ne 0 ] && _pass "grype scanning nothing exits non-zero" || _fail "grype scanning nothing exits non-zero" "rc 0"
  [ -z "$g_kind" ] && _pass "…leaves no receipt" || _fail "…leaves no receipt" "receipt kind '$g_kind'"
  [ "$g_matches" = 1 ] && _pass "…and does not overwrite the previous result with an empty one" \
    || _fail "…and does not overwrite the previous result with an empty one" "matches now $g_matches"
  echo "$g_out" | grep -q "Scan: FAIL" && echo "$g_out" | grep -q "did not run:.*grype" \
    && _pass "…so the verdict is FAIL and names grype" \
    || _fail "…so the verdict is FAIL and names grype" "got: $g_out"
  rm -rf "$dir"
fi

echo ""
echo "=== Group 8: ClamAV signature freshness guard ==="

fresh_fixture() {   # fresh_fixture <version-line-for-clamscan>
  local state; state=$(mktemp -d)
  mkdir -p "$state/bin" "$state/results"
  printf '%s\n' "$1" > "$state/version"
  cat > "$state/bin/clamscan" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = --version ] && { cat "$FAKE_STATE/version"; exit 0; }
done
printf '\n----------- SCAN SUMMARY -----------\nInfected files: 0\n'
exit 0
FAKE
  cat > "$state/bin/freshclam" <<'FAKE'
#!/usr/bin/env bash
echo ran >> "$FAKE_STATE/freshclam.calls"
if [ "${FAKE_FRESHCLAM_FAIL:-0}" = 1 ]; then echo "ERROR: Can't download daily.cvd"; exit 1; fi
if [ "${FAKE_FRESHCLAM_NOOP:-0}" = 1 ]; then echo "up to date"; exit 0; fi
printf 'ClamAV 9.9.9/99999/%s\n' "$(date '+%a %b %d %T %Y')" > "$FAKE_STATE/version"
exit 0
FAKE
  chmod +x "$state/bin/clamscan" "$state/bin/freshclam"
  printf '%s' "$state"
}

guard_case() {
  local label="$1" version="$2" want_exit="$3" want_grep="$4"; shift 4
  local state out code=0
  state=$(fresh_fixture "$version")
  out=$(cd "$PROJECT_ROOT" && env "$@" \
        FAKE_STATE="$state" PATH="$state/bin:$PATH" SCAN_ENGINE=native \
        SCAN_RESULTS_DIR="$state/results" SCAN_DIR_OVERRIDE="$state/results" \
        bash "$SCAN_DIR/run-clamav.sh" 2>&1) || code=$?

  if [[ $code -ne $want_exit ]]; then
    _fail "$label" "expected exit $want_exit, got $code — output: $out"
  elif ! echo "$out" | grep -q "$want_grep"; then
    _fail "$label" "expected '$want_grep' in: $out"
  else
    _pass "$label"
  fi
  GUARD_LAST_STATE="$state"
  GUARD_LAST_OUT="$out"
}

NOW_VERSION="ClamAV 1.4.3/27712/$(date '+%a %b %d %T %Y')"
OLD_VERSION="ClamAV 1.4.3/27000/$(date -d '30 days ago' '+%a %b %d %T %Y' 2>/dev/null \
              || date -v-30d '+%a %b %d %T %Y')"

guard_case "guard: current signatures scan without a refresh" \
  "$NOW_VERSION" 0 "Signature database: 0 day(s) old"
if [[ -f "$GUARD_LAST_STATE/freshclam.calls" ]]; then
  _fail "guard: current signatures do not trigger freshclam" "freshclam ran anyway"
else
  _pass "guard: current signatures do not trigger freshclam"
fi
rm -rf "$GUARD_LAST_STATE"

guard_case "guard: stale signatures are refreshed and the scan proceeds" \
  "$OLD_VERSION" 0 "Signatures refreshed"
if [[ -f "$GUARD_LAST_STATE/freshclam.calls" ]]; then
  _pass "guard: stale signatures trigger freshclam"
else
  _fail "guard: stale signatures trigger freshclam" "freshclam was never called"
fi
rm -rf "$GUARD_LAST_STATE"

guard_case "guard: a failed refresh blocks the scan" \
  "$OLD_VERSION" 1 "STALE SIGNATURES" FAKE_FRESHCLAM_FAIL=1
echo "$GUARD_LAST_OUT" | grep -q "FRESHCLAM FAILED" \
  && _pass "guard: a failed refresh prints why, not just a pointer to a log" \
  || _fail "guard: a failed refresh prints why, not just a pointer to a log" "got: $GUARD_LAST_OUT"
rm -rf "$GUARD_LAST_STATE"

guard_case "guard: a refresh that does not help still blocks" \
  "$OLD_VERSION" 1 "STALE SIGNATURES" FAKE_FRESHCLAM_NOOP=1
if echo "$GUARD_LAST_OUT" | grep -qi "bump the tag"; then
  _fail "guard: stale advice is actionable" "still says 'bump the tag', which cannot clear this"
else
  _pass "guard: stale advice is actionable"
fi
rm -rf "$GUARD_LAST_STATE"

guard_case "guard: an unreadable signature date blocks the scan" \
  "garbage with no date" 1 "UNVERIFIED SIGNATURES" FAKE_FRESHCLAM_NOOP=1
if echo "$GUARD_LAST_OUT" | grep -q "no infections found"; then
  _fail "guard: an unreadable signature date never reports clean" "it reported no infections found"
else
  _pass "guard: an unreadable signature date never reports clean"
fi
rm -rf "$GUARD_LAST_STATE"

guard_case "guard: the unverified override runs the scan" \
  "garbage with no date" 0 "no infections found" \
  FAKE_FRESHCLAM_NOOP=1 CLAMAV_ALLOW_UNVERIFIED_SIGNATURES=1
if printf '%s\n' "$GUARD_LAST_OUT" | grep '^\[clamav\] PASS' | grep -q "UNVERIFIED"; then
  _pass "guard: the overridden pass is marked UNVERIFIED"
else
  _fail "guard: the overridden pass is marked UNVERIFIED" \
    "the PASS line reads as an ordinary clean: $(printf '%s\n' "$GUARD_LAST_OUT" | grep '^\[clamav\] PASS')"
fi
rm -rf "$GUARD_LAST_STATE"

if grep -q '^tool_freshclam()' "$SCAN_DIR/tool-runner.sh"; then
  _pass "tool-runner.sh provides tool_freshclam"
else
  _fail "tool-runner.sh provides tool_freshclam" "no freshclam wrapper — the guard has no remedy"
fi
if [[ $(grep -c 'CLAMAV_DB_VOLUME:/var/lib/clamav' "$SCAN_DIR/tool-runner.sh") -eq 2 ]]; then
  _pass "clamscan and freshclam share one signature volume"
else
  _fail "clamscan and freshclam share one signature volume" \
    "both must mount the db volume or the refresh is discarded by --rm"
fi

echo ""
echo "=== Group 9: A crashed scanner must not read as clean ==="

cj() { ( . "$RUNNER" >/dev/null 2>&1; count_json "$1" "$2" probe ) 2>/dev/null; }

_tmp9="$(mktemp -d)"

printf 'Unable to find image "hadolint/hadolint:v2.12.0-alpine" locally\ndocker: Error response from daemon.\n' > "$_tmp9/blob.json"
if out=$(cj "$_tmp9/blob.json" '[.[] | select(.level == "error")] | length'); then
  _fail "an error blob is rejected, not counted as 0" "returned '$out' and succeeded"
else
  [[ -z "$out" ]] && _pass "an error blob is rejected, not counted as 0" \
                  || _fail "an error blob is rejected, not counted as 0" "printed '$out' while failing"
fi

: > "$_tmp9/empty.json"
if out=$(cj "$_tmp9/empty.json" '. | length'); then
  _fail "an empty results file is rejected" "returned '$out' and succeeded"
else
  _pass "an empty results file is rejected"
fi

if out=$(cj "$_tmp9/missing.json" '. | length'); then
  _fail "a missing results file is rejected" "returned '$out' and succeeded"
else
  _pass "a missing results file is rejected"
fi

printf '{"results":{}}' > "$_tmp9/shape.json"
if out=$(cj "$_tmp9/shape.json" '(.results.failed_checks // error("missing")) | length'); then
  _fail "a vanished key is rejected, not counted as 0" "returned '$out'"
else
  _pass "a vanished key is rejected, not counted as 0"
fi

printf '{"results":{}}' > "$_tmp9/shape.json"
out=$(cj "$_tmp9/shape.json" '.results.failed_checks | length')
if [[ "$out" == "0" ]]; then
  _pass "confirms why: the un-asserted filter yields a silent 0"
else
  _fail "confirms why: the un-asserted filter yields a silent 0" "got '$out'"
fi

if grep -nE "count_json" "$SCAN_DIR"/run-*.sh | grep -qvE 'error\(|\[\]\?|\.\[\]|RESULTS_DIR|tmp_json|\\$'; then
  :  # informational only; the per-filter assertions above are the real check
fi

printf '[{"level":"error"},{"level":"warning"},{"level":"error"}]' > "$_tmp9/real.json"
out=$(cj "$_tmp9/real.json" '[.[] | select(.level == "error")] | length')
if [[ "$out" == "2" ]]; then
  _pass "a real results file still counts correctly (2 errors)"
else
  _fail "a real results file still counts correctly" "got '$out', expected 2"
fi

if grep -q 'jq.*|| echo "0"' "$SCAN_DIR"/run-*.sh 2>/dev/null; then
  _fail "no runner reads a count with a '|| echo 0' fallback" \
    "$(grep -l 'jq.*|| echo \"0\"' "$SCAN_DIR"/run-*.sh | tr '\n' ' ')"
else
  _pass "no runner reads a count with a '|| echo 0' fallback"
fi

_old_path='_scan''-results'
if grep -rq --exclude-dir=tests "$_old_path" "$SCAN_DIR"/../ 2>/dev/null; then
  _fail "no scanner still writes an old results path" \
    "$(grep -rl --exclude-dir=tests "$_old_path" "$SCAN_DIR"/../ 2>/dev/null | head -3 | tr '\n' ' ')"
else
  _pass "no scanner still writes an old results path"
fi

if grep -q 'check-ignore' "$SCAN_DIR/run-hadolint.sh"; then
  _pass "run-hadolint skips gitignored Dockerfiles"
else
  _fail "run-hadolint skips gitignored Dockerfiles" "no check-ignore filter in the discovery loop"
fi

if grep -qE 'run_framework "helm"[[:space:]]+"helm"' "$SCAN_DIR/run-checkov.sh"; then
  _pass "checkov scans the helm chart root, not helm/templates"
else
  _fail "checkov scans the helm chart root, not helm/templates" \
    "$(grep -E 'run_framework "helm"' "$SCAN_DIR/run-checkov.sh" | head -1)"
fi

if grep -q 'NOTHING SCANNED' "$SCAN_DIR/run-checkov.sh"; then
  _pass "a checkov run that parses 0 resources says so instead of passing quietly"
else
  _fail "a checkov run that parses 0 resources says so instead of passing quietly" "no notice"
fi

rm -rf "$_tmp9"

if [ -z "$_LIVE_RESULTS" ] || [ -z "$_LIVE_BEFORE" ]; then
  _skip "the self-tests left .gatekit/records/scan-latest untouched" \
    "no readable live results directory here — nothing to compare, so nothing is claimed"
elif _live_after="$(_live_manifest)" && [ "$_live_after" = "$_LIVE_BEFORE" ]; then
  _pass "the self-tests left .gatekit/records/scan-latest untouched"
else
  _fail "the self-tests left .gatekit/records/scan-latest untouched" \
    "a case wrote into the live results directory — it is missing SCAN_RESULTS_DIR"
fi

echo ""
echo "════════════════════════════════════════"
TOTAL=$((PASS + FAIL + SKIP))
echo "Results: $PASS passed  $FAIL failed  $SKIP skipped  ($TOTAL total)"
echo "════════════════════════════════════════"

[[ $FAIL -eq 0 ]]
