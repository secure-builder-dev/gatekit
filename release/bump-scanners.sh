#!/usr/bin/env bash
# bump-scanners.sh — move each pinned scanner in .gatekit/scan/tool-versions.env to its newest
# release on Docker Hub. Run weekly by .github/workflows/release.yml; prints what moved.
#
# ClamAV stays on its moving `stable` tag on purpose: its virus signatures ship inside the image,
# so pinning it would freeze the signatures.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
F=.gatekit/scan/tool-versions.env

# latest REPO PREFIX SUFFIX — newest tag shaped PREFIX<x.y.z>SUFFIX
latest() {
  local repo="$1" pre="$2" suf="$3"
  curl -fsSL "https://hub.docker.com/v2/repositories/$repo/tags?page_size=100&ordering=last_updated" \
    | jq -r '.results[].name' \
    | grep -E "^${pre}[0-9]+\.[0-9]+\.[0-9]+${suf}\$" \
    | sed -E "s/^${pre}//; s/${suf}\$//" | sort -V | tail -1
}

bump() {   # VAR REPO PREFIX SUFFIX
  local var="$1" repo="$2" pre="$3" suf="$4" cur new
  cur="$(sed -nE "s/^${var}=\"\\\$\\{${var}:-${repo//\//\\/}:${pre}([0-9.]+)${suf}\\}\"/\\1/p" "$F")"
  new="$(latest "$repo" "$pre" "$suf")" || true
  if [ -z "$cur" ] || [ -z "$new" ]; then echo "  $repo: couldn't read (current '${cur:-?}', latest '${new:-?}') — left alone"; return; fi
  if [ "$cur" = "$new" ]; then echo "  $repo: $cur (current)"; return; fi
  sed -i.bak -E "s#(${var}=\"\\\$\\{${var}:-${repo}:${pre})${cur}(${suf}\\}\")#\\1${new}\\2#" "$F" && rm -f "$F.bak"
  echo "  $repo: $cur → $new"
}

bump SCAN_IMAGE_HADOLINT hadolint/hadolint v -alpine
bump SCAN_IMAGE_CHECKOV  bridgecrew/checkov "" ""
bump SCAN_IMAGE_GRYPE    anchore/grype v ""
bump SCAN_IMAGE_TRIVY    aquasec/trivy "" ""
