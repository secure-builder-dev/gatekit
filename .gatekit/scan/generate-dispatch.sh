#!/usr/bin/env bash
# generate-dispatch.sh — read the scanner results and sort every finding into "fixable" (dispatch.md) or "no fix yet" (poam-candidates.md). Runs no scanners itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SCAN_RESULTS_DIR="${SCAN_RESULTS_DIR:-$PROJECT_ROOT/.gatekit/records/scan-latest}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCAN_RESULTS_DIR}"

GRYPE_JSON="$SCAN_RESULTS_DIR/grype.json"
TRIVY_JSON="$SCAN_RESULTS_DIR/trivy.json"
HADOLINT_JSON="$SCAN_RESULTS_DIR/hadolint.json"
CHECKOV_JSON="$SCAN_RESULTS_DIR/checkov.json"
CLAMAV_LOG="$SCAN_RESULTS_DIR/clamav.log"
AUDIT_JSON="$SCAN_RESULTS_DIR/audit.json"
ESLINT_JSON="$SCAN_RESULTS_DIR/eslint.json"

DISPATCH_FILE="$OUTPUT_DIR/dispatch.md"
POAM_FILE="$OUTPUT_DIR/poam-candidates.md"
DISCREPANCY_LOG="$OUTPUT_DIR/discrepancy.log"

rm -f "$DISPATCH_FILE" "$POAM_FILE" "$DISCREPANCY_LOG"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

if ! command -v jq >/dev/null 2>&1; then
  echo "[generate-dispatch] ERROR: jq is required. Install via brew install jq or apt install jq."
  exit 1
fi

pkg_blocks=""
infra_blocks=""
poam_blocks=""

has_pkg=false
has_infra=false
has_poam=false
has_clamav_infection=false

clamav_status="N/A"
hadolint_status="N/A"
checkov_status="N/A"
image_scan_status="SKIPPED"

hadolint_self_healing=0; hadolint_poam=0
checkov_self_healing=0; checkov_poam=0
image_self_healing=0;   image_poam=0
clamav_self_healing=0;  clamav_poam=0
npm_audit_status="N/A"; npm_audit_self_healing=0; npm_audit_poam=0; npm_audit_reported=0
eslint_status="N/A"; eslint_self_healing=0; eslint_poam=0

clamav_critical_block=""

process_clamav() {
  [[ ! -f "$CLAMAV_LOG" ]] && return
  clamav_status="PASS"
  local infected_count
  infected_count=$(grep -oE 'Infected files: [0-9]+' "$CLAMAV_LOG" | grep -oE '[0-9]+' || echo "0")
  if [[ "$infected_count" -gt 0 ]]; then
    has_clamav_infection=true
    clamav_status="FAIL"
    clamav_self_healing=$infected_count
    local infected_files
    infected_files=$(grep " FOUND$" "$CLAMAV_LOG" 2>/dev/null || echo "(see clamav.log)")
    clamav_critical_block="## ClamAV — INFECTION DETECTED (CRITICAL)

\`\`\`
$infected_files
\`\`\`

**SEVERITY: CRITICAL — DO NOT COMMIT. Remove infected files before continuing.**
See \`$SCAN_RESULTS_DIR/clamav.log\` for full scan output.

"
  fi
}

process_hadolint() {
  [[ ! -f "$HADOLINT_JSON" ]] && return
  hadolint_status="PASS"
  local error_count
  error_count=$(jq '[.[] | select(.level == "error")] | length' "$HADOLINT_JSON" 2>/dev/null || echo "0")
  [[ "$error_count" -eq 0 ]] && return

  hadolint_status="FAIL"
  hadolint_self_healing=$error_count
  has_infra=true

  while IFS=$'\t' read -r file line code message; do
    [[ -z "$code" ]] && continue
    infra_blocks+="### $code — $message

- **File:** $file
- **Line:** $line
- **Severity:** error
- **Action:** Fix the hadolint violation in \`$file\` at line $line. See https://github.com/hadolint/hadolint/wiki/$code for details.

"
  done < <(jq -r '.[] | select(.level == "error") | [.file, (.line | tostring), .code, .message] | @tsv' \
    "$HADOLINT_JSON" 2>/dev/null || true)
}

process_checkov() {
  [[ ! -f "$CHECKOV_JSON" ]] && return
  checkov_status="PASS"
  local fail_count
  fail_count=$(jq '.results.failed_checks | length' "$CHECKOV_JSON" 2>/dev/null || echo "0")
  [[ "$fail_count" -eq 0 ]] && return

  checkov_status="FAIL"
  checkov_self_healing=$fail_count
  has_infra=true

  while IFS=$'\t' read -r check_id file line_s line_e severity description; do
    [[ -z "$check_id" ]] && continue
    infra_blocks+="### $check_id — $description

- **File:** $file
- **Line:** $line_s–$line_e
- **Severity:** $severity
- **Action:** Fix the resource; suppress a per-resource false positive with a \`checkov.io/skipN: "$check_id=reason"\` annotation; or add a bounded entry to \`.gatekit/checkov-justifications.yaml\`. See https://www.checkov.io for the check.

"
  done < <(jq -r '.results.failed_checks[] |
    [
      .check_id,
      (.file_path // "?"),
      ((.file_line_range[0] // 0) | tostring),
      ((.file_line_range[1] // 0) | tostring),
      (.severity // "unrated (checkov OSS emits no severity)"),
      (.check_name // .check_description // .check_id)
    ] | @tsv' "$CHECKOV_JSON" 2>/dev/null || true)
}

process_npm_audit() {
  [[ ! -f "$AUDIT_JSON" ]] && return
  npm_audit_status="PASS"
  npm_audit_reported=$(jq '.reported | length' "$AUDIT_JSON" 2>/dev/null || echo "0")
  local n
  n=$(jq '.blocking | length' "$AUDIT_JSON" 2>/dev/null || echo "0")
  [[ "$n" -eq 0 ]] && return

  npm_audit_status="FAIL"
  npm_audit_self_healing=$n
  has_pkg=true

  while IFS=$'\t' read -r app id severity pkg range fix direct url title; do
    [[ -z "$id" ]] && continue
    local remedy="\`make patch\` (npm audit fix, then your tests); stage \`$app/package.json\` and \`$app/package-lock.json\` together"
    if [[ "$fix" == *"(major)"* ]]; then
      remedy="manual bump to \`$fix\` — \`npm audit fix\` does not cross a major; run the app's build and suite after"
    elif [[ "$fix" == "none" ]]; then
      remedy="no fixed version published — replace the package, or add an allowlist entry with reason, owner and expiry to \`.gatekit/npm-audit-allowlist.yaml\`"
    fi
    local dep_label="transitive"
    [[ "$direct" == "true" ]] && dep_label="direct"
    pkg_blocks+="### $id — ${pkg} (${app}, ${severity})

- **Advisory:** ${title} — ${url}
- **Vulnerable range:** \`${range}\`
- **Fix available:** \`${fix}\`
- **Dependency type:** $dep_label
- **Found by:** npm audit over all dependencies, dev included
- **Action:** $remedy

"
  done < <(jq -r '.blocking[] | [.app, .id, .severity, .package, .range, .fix, (.direct | tostring), .url, .title] | @tsv' \
    "$AUDIT_JSON" 2>/dev/null || true)
}

process_eslint() {
  [[ ! -f "$ESLINT_JSON" ]] && return
  eslint_status="PASS"
  local n
  n=$(jq '.blocking | length' "$ESLINT_JSON" 2>/dev/null || echo "0")
  [[ "$n" -eq 0 ]] && return

  eslint_status="FAIL"
  eslint_self_healing=$(jq '[.blocking[] | .app + "/" + .file] | unique | length' "$ESLINT_JSON" 2>/dev/null || echo "$n")
  has_pkg=true

  while IFS=$'\t' read -r app file count; do
    [[ -z "$file" ]] && continue
    local lines
    lines=$(jq -r --arg app "$app" --arg file "$file" '
      .blocking[] | select(.app == $app and .file == $file)
      | "- line \(.line):\(.column) — `\(.rule)` (\(.severity)): \(.message)"' "$ESLINT_JSON" 2>/dev/null)
    pkg_blocks+="### eslint — ${app}/${file} (${count} message$([[ "$count" -eq 1 ]] || echo s))

${lines}
- **Action:** fix every message above and re-run \`cd ${app} && npm run lint\`; both apps lint with \`--max-warnings 0\`, so warnings count.

"
  done < <(jq -r '.blocking | group_by(.app + "/" + .file)[] | [.[0].app, .[0].file, (length | tostring)] | @tsv' \
    "$ESLINT_JSON" 2>/dev/null || true)
}

process_image_scans() {
  local grype_present=false trivy_present=false
  [[ -f "$GRYPE_JSON" ]] && grype_present=true
  [[ -f "$TRIVY_JSON" ]] && trivy_present=true
  $grype_present || $trivy_present || return
  image_scan_status="PASS"

  local grype_src="$GRYPE_JSON"
  local trivy_src="$TRIVY_JSON"
  $grype_present || grype_src="/dev/null"
  $trivy_present || trivy_src="/dev/null"

  local grype_npm_fixed="" trivy_npm_fixed=""

  if $grype_present; then
    grype_npm_fixed=$(jq -r '
      .matches[]? |
      select(.artifact.type == "npm") |
      select(.vulnerability.fix.state == "fixed") |
      select((.vulnerability.fix.versions | length) > 0) |
      .vulnerability.id
    ' "$grype_src" 2>/dev/null | sort -u || true)
  fi

  if $trivy_present; then
    trivy_npm_fixed=$(jq -r '
      .Results[]? |
      select(.Type == "node-pkgs") |
      .Vulnerabilities[]? |
      select(.FixedVersion != null and .FixedVersion != "") |
      .VulnerabilityID
    ' "$trivy_src" 2>/dev/null | sort -u || true)
  fi

  local both_ids="" grype_only="" trivy_only=""
  if [[ -n "$grype_npm_fixed" && -n "$trivy_npm_fixed" ]]; then
    both_ids=$(comm -12  <(echo "$grype_npm_fixed") <(echo "$trivy_npm_fixed") 2>/dev/null || true)
    grype_only=$(comm -23 <(echo "$grype_npm_fixed") <(echo "$trivy_npm_fixed") 2>/dev/null || true)
    trivy_only=$(comm -13 <(echo "$grype_npm_fixed") <(echo "$trivy_npm_fixed") 2>/dev/null || true)
  elif [[ -n "$grype_npm_fixed" ]]; then
    grype_only="$grype_npm_fixed"
  elif [[ -n "$trivy_npm_fixed" ]]; then
    trivy_only="$trivy_npm_fixed"
  fi

  while IFS= read -r cve_id; do
    [[ -z "$cve_id" ]] && continue
    image_scan_status="FAIL"
    has_pkg=true
    image_self_healing=$((image_self_healing + 1))

    local pkg="" installed="" fixed="" severity="" cvss="" dep_type=""
    local raw
    raw=$(jq -r --arg cve "$cve_id" '
      .matches[] |
      select(.vulnerability.id == $cve and .artifact.type == "npm") |
      [
        .artifact.name,
        .artifact.version,
        (.vulnerability.fix.versions[0] // "unknown"),
        .vulnerability.severity,
        ((.vulnerability.cvss[0].metrics.baseScore // "N/A") | tostring),
        (.matchDetails[0].type // "")
      ] | @tsv
    ' "$grype_src" 2>/dev/null | head -1 || true)

    if [[ -n "$raw" ]]; then
      IFS=$'\t' read -r pkg installed fixed severity cvss dep_type <<< "$raw"
    fi

    local dep_label="direct"
    if echo "$dep_type" | grep -qi "indirect\|transitive"; then
      dep_label="transitive"
    fi

    pkg_blocks+="### $cve_id — ${pkg}@${installed}

- **Fix available:** \`${pkg}@${fixed}\`
- **Severity:** $severity
- **CVSS:** $cvss
- **Found in:** Grype + Trivy (both)
- **Dependency type:** $dep_label
- **Action:** \`npm install ${pkg}@${fixed}\` — then run full test suite. Stage both \`package.json\` and \`package-lock.json\` in the remediation commit.

"
  done <<< "$both_ids"

  mkdir -p "$OUTPUT_DIR"
  {
    echo "# Discrepancy Log — $TIMESTAMP"
    echo ""
    echo "CVEs found by only one scanner. Excluded from dispatch.md — verify with both tools."
    echo ""
  } > "$DISCREPANCY_LOG"

  while IFS= read -r cve_id; do
    [[ -z "$cve_id" ]] && continue
    local pkg="" installed=""
    raw=$(jq -r --arg cve "$cve_id" '
      .matches[] | select(.vulnerability.id == $cve and .artifact.type == "npm") |
      [.artifact.name, .artifact.version] | @tsv
    ' "$grype_src" 2>/dev/null | head -1 || true)
    [[ -n "$raw" ]] && IFS=$'\t' read -r pkg installed <<< "$raw"
    echo "- $cve_id | ${pkg}@${installed} | found in: GRYPE only" >> "$DISCREPANCY_LOG"
  done <<< "$grype_only"

  while IFS= read -r cve_id; do
    [[ -z "$cve_id" ]] && continue
    local pkg="" installed=""
    raw=$(jq -r --arg cve "$cve_id" '
      .Results[]? | select(.Type == "node-pkgs") | .Vulnerabilities[]? |
      select(.VulnerabilityID == $cve) |
      [.PkgName, .InstalledVersion] | @tsv
    ' "$trivy_src" 2>/dev/null | head -1 || true)
    [[ -n "$raw" ]] && IFS=$'\t' read -r pkg installed <<< "$raw"
    echo "- $cve_id | ${pkg}@${installed} | found in: TRIVY only" >> "$DISCREPANCY_LOG"
  done <<< "$trivy_only"

  if $grype_present; then
    while IFS=$'\t' read -r cve_id pkg installed severity cvss; do
      [[ -z "$cve_id" ]] && continue
      has_poam=true
      image_scan_status="FAIL"
      image_poam=$((image_poam + 1))
      poam_blocks+="## $cve_id — $pkg

- **Severity:** $severity
- **CVSS:** $cvss
- **Affected component:** ${pkg}@${installed}
- **Fix availability:** No upstream fix available
- **Reason for POAM routing:** No fixed version released as of scan date.
- **Next step:** Follow \`.gatekit/POAM-GUIDE.md\` to get it onto your POAM.

"
    done < <(jq -r '
      .matches[]? |
      select(.artifact.type == "npm") |
      select(.vulnerability.fix.state != "fixed" or (.vulnerability.fix.versions | length) == 0) |
      [
        .vulnerability.id,
        .artifact.name,
        .artifact.version,
        .vulnerability.severity,
        ((.vulnerability.cvss[0].metrics.baseScore // "N/A") | tostring)
      ] | @tsv
    ' "$grype_src" 2>/dev/null || true)
  fi

  if $grype_present; then
    while IFS=$'\t' read -r cve_id pkg installed artifact_type severity cvss; do
      [[ -z "$cve_id" ]] && continue
      has_poam=true
      image_scan_status="FAIL"
      image_poam=$((image_poam + 1))
      poam_blocks+="## $cve_id — $pkg

- **Severity:** $severity
- **CVSS:** $cvss
- **Affected component:** ${pkg}@${installed} (type: $artifact_type)
- **Fix availability:** Base image layer (fixed by a newer base image, not by your code)
- **Reason for POAM routing:** OS-level package ($artifact_type) in the container's base image. It clears when you rebuild on a newer base image that includes the fix.
- **Next step:** Follow \`.gatekit/POAM-GUIDE.md\` to get it onto your POAM.

"
    done < <(jq -r '
      .matches[]? |
      select(.artifact.type != "npm") |
      [
        .vulnerability.id,
        .artifact.name,
        .artifact.version,
        .artifact.type,
        .vulnerability.severity,
        ((.vulnerability.cvss[0].metrics.baseScore // "N/A") | tostring)
      ] | @tsv
    ' "$grype_src" 2>/dev/null || true)
  fi
}

write_output() {
  mkdir -p "$OUTPUT_DIR"

  if $has_poam; then
    {
      echo "# POAM Candidates — $TIMESTAMP"
      echo ""
      echo "These have no fix yet. They go on your POAM; they do not block your PR."
      echo "Follow \`.gatekit/POAM-GUIDE.md\` for the POAM submission process."
      echo ""
      printf '%s' "$poam_blocks"
    } > "$POAM_FILE"
    echo "[generate-dispatch] Written: $POAM_FILE"
  fi

  local self_healing_exists=false
  ($has_pkg || $has_infra || $has_clamav_infection) && self_healing_exists=true

  if ! $self_healing_exists; then
    echo "[generate-dispatch] No self-healing items found — dispatch.md not written"
    return 0
  fi

  {
    echo "# Scan results — $TIMESTAMP"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Tool | Status | Self-healing findings | POAM candidates |"
    echo "|---|---|---|---|"
    echo "| hadolint | $hadolint_status | $hadolint_self_healing | $hadolint_poam |"
    echo "| Checkov | $checkov_status | $checkov_self_healing | $checkov_poam |"
    echo "| ClamAV | $clamav_status | $clamav_self_healing | $clamav_poam |"
    echo "| Grype+Trivy | $image_scan_status | $image_self_healing | $image_poam |"
    echo "| npm audit | $npm_audit_status | $npm_audit_self_healing | $npm_audit_poam |"
    echo "| eslint | $eslint_status | $eslint_self_healing | $eslint_poam |"
    [[ "$npm_audit_reported" -gt 0 ]] && echo "" && echo "npm audit also reported $npm_audit_reported Moderate/Low advisor$([[ "$npm_audit_reported" -eq 1 ]] && echo y || echo ies) — not blocking, listed in \`audit.log\`."
    echo ""

    if $has_clamav_infection; then
      printf '%s' "$clamav_critical_block"
    fi

    if $has_pkg; then
      echo "## Package and lint fixes (make patch handles these)"
      echo ""
      printf '%s' "$pkg_blocks"
    fi

    if $has_infra; then
      echo "## Dockerfile / Helm / Terraform fixes"
      echo ""
      printf '%s' "$infra_blocks"
    fi

    if $has_poam; then
      echo "## POAM Candidates (No Self-Healing — Manual Review Required)"
      echo ""
      echo "See \`poam-candidates.md\` in your branch's records folder for the full list."
      echo "Follow \`.gatekit/POAM-GUIDE.md\` for POAM submission process."
      echo ""
    fi

    echo "---"
    echo ""
    echo "## What happens next"
    echo ""
    echo "\`make scans\` runs \`make patch\` on these automatically. Anything patch cannot fix with your"
    echo "tests still green becomes a ticket on your branch."
  } > "$DISPATCH_FILE"

  echo "[generate-dispatch] Written: $DISPATCH_FILE"
}

process_clamav
process_hadolint
process_checkov
process_npm_audit
process_eslint
process_image_scans
write_output
