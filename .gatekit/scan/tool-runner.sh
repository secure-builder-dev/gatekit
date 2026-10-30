#!/usr/bin/env bash
# tool-runner.sh — run a scanner either as a Docker/Podman container (default) or a locally installed tool (SCAN_ENGINE=native). Versions: tool-versions.env.

_TR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_TR_DIR/../.." && pwd)}"
# shellcheck source=tool-versions.env
. "$_TR_DIR/tool-versions.env"

SCAN_ENGINE="${SCAN_ENGINE:-auto}"
_tr_engine=""

scan_engine() {
  if [ -z "$_tr_engine" ]; then
    case "$SCAN_ENGINE" in
      container) _tr_engine=container ;;
      native)    _tr_engine=native ;;
      auto|"")   if docker info >/dev/null 2>&1; then _tr_engine=container; else _tr_engine=native; fi ;;
      *) echo "[scan] SCAN_ENGINE='$SCAN_ENGINE' is not auto|container|native" >&2; return 2 ;;
    esac
  fi
  echo "$_tr_engine"
}

have_tool() {
  if [ "$(scan_engine)" = container ]; then docker info >/dev/null 2>&1
  else command -v "$1" >/dev/null 2>&1; fi
}

tool_missing() {
  if [ "$(scan_engine)" = container ]; then
    echo "[$1] Docker is not usable, so the pinned $1 image cannot run."
    echo "[$1]   Start Docker, or SCAN_ENGINE=native with $2 installed (see the gatekit README)."
  else
    echo "[$1] NOT INSTALLED — SCAN_ENGINE=native and '$2' is not on PATH."
    echo "[$1]   Install it (see the gatekit README), or unset SCAN_ENGINE to use containers."
  fi
}

_tr_user() { [ "$(uname -s)" = Linux ] && printf -- '--user %s:%s' "$(id -u)" "$(id -g)"; }

_tr_clamav_platform() {
  [ -n "${SCAN_PLATFORM_CLAMAV:-}" ] && printf -- '--platform %s' "$SCAN_PLATFORM_CLAMAV"
}

count_json() {
  local file="$1" filter="$2" label="$3" n
  if [ ! -s "$file" ]; then
    echo "[$label] FAIL — $file is empty or missing. The scanner did not run." >&2
    return 2
  fi
  if ! n=$(jq -e "$filter" "$file" 2>/dev/null); then
    echo "[$label] FAIL — $file is not parseable JSON. The scanner did not complete." >&2
    echo "[$label]   $file begins: $(head -c 160 "$file" | tr '\n' ' ')" >&2
    mv -f "$file" "$file.unparseable" 2>/dev/null \
      && echo "[$label]   moved aside to $file.unparseable — the results directory now shows this scanner as not run" >&2
    return 2
  fi
  case "$n" in (''|*[!0-9]*) echo "[$label] FAIL — expected a count, got '$n'." >&2; return 2 ;; esac
  printf '%s' "$n"
}

tool_hadolint() {
  if [ "$(scan_engine)" = native ]; then hadolint "$@"; else
    # shellcheck disable=SC2046
    docker run --rm $(_tr_user) -v "$PROJECT_ROOT:/src:ro" -w /src \
      --entrypoint hadolint "$SCAN_IMAGE_HADOLINT" "$@"
  fi
}

tool_checkov() {
  if [ "$(scan_engine)" = native ]; then checkov "$@"; else
    # shellcheck disable=SC2046
    docker run --rm $(_tr_user) -v "$PROJECT_ROOT:/src:ro" -w /src \
      --entrypoint checkov "$SCAN_IMAGE_CHECKOV" "$@"
  fi
}

_TR_CLAMAV_DB_VOLUME="${SCAN_CLAMAV_DB_VOLUME:-scan-clamav-db}"

tool_clamscan() {
  local target="$1"; shift
  if [ "$(scan_engine)" = native ]; then clamscan "$@" "$target"; else
    # shellcheck disable=SC2046
    docker run --rm $(_tr_clamav_platform) -v "$target:/scan:ro" -v "$_TR_CLAMAV_DB_VOLUME:/var/lib/clamav" \
      "$SCAN_IMAGE_CLAMAV" clamscan "$@" /scan
  fi
}

tool_freshclam() {
  if [ "$(scan_engine)" = native ]; then freshclam "$@"; else
    # shellcheck disable=SC2046
    docker run --rm $(_tr_clamav_platform) -v "$_TR_CLAMAV_DB_VOLUME:/var/lib/clamav" \
      "$SCAN_IMAGE_CLAMAV" freshclam "$@"
  fi
}

tool_grype() {
  if [ "$(scan_engine)" = native ]; then grype "$@"; else
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$PROJECT_ROOT:/src:ro" -w /src \
      -v scan-grype-cache:/.cache "$SCAN_IMAGE_GRYPE" "$@"
  fi
}

tool_trivy() {
  if [ "$(scan_engine)" = native ]; then trivy "$@"; else
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$PROJECT_ROOT:/src:ro" -w /src \
      -v scan-trivy-cache:/root/.cache "$SCAN_IMAGE_TRIVY" "$@"
  fi
}
