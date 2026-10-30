#!/usr/bin/env bash
# image-age-guard.sh — refuse to scan an old Docker image as if it were current. Tune with SCAN_MAX_IMAGE_AGE_HOURS, or SCAN_ALLOW_STALE=1 to accept it.

_ts_to_epoch() {
  local ts="${1%%.*}"; ts="${ts%Z}"; ts="${ts%+00:00}"
  date -u -d "$ts" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null && return 0
  echo ""
}

guard_image_age() {
  local max_hours="${SCAN_MAX_IMAGE_AGE_HOURS:-24}"
  [ "$max_hours" = "0" ] && return 0

  local now stale=0 img created epoch age_h
  now=$(date -u +%s)

  for img in "$@"; do
    docker image inspect "$img" >/dev/null 2>&1 || continue
    created=$(docker image inspect "$img" --format '{{.Created}}' 2>/dev/null)
    epoch=$(_ts_to_epoch "$created")
    if [ -z "$epoch" ]; then
      echo "[age] WARNING — cannot read build time for $img; its age is unverified."
      continue
    fi
    age_h=$(( (now - epoch) / 3600 ))
    if [ "$age_h" -gt "$max_hours" ]; then
      stale=$((stale + 1))
      echo "[age] STALE: $img was built ${age_h}h ago (limit ${max_hours}h)."
    fi
  done

  [ "$stale" -eq 0 ] && return 0

  echo ""
  echo "[age] $stale image(s) exceed ${max_hours}h. Findings from them describe an OLD BUILD, not"
  echo "[age] the current tree: CVEs already fixed upstream will still be listed, and packages"
  echo "[age] added since will be missing entirely. This is NOT evidence."
  echo "[age]   Rebuild:           bash .gatekit/scan/build-images.sh"
  echo "[age]   Accept the risk:   SCAN_ALLOW_STALE=1 make scans"
  echo "[age]   Widen the window:  SCAN_MAX_IMAGE_AGE_HOURS=72 make scans"

  if [ "${SCAN_ALLOW_STALE:-0}" = "1" ]; then
    echo "[age] SCAN_ALLOW_STALE=1 — continuing. Do not file this run as a clean scan."
    return 0
  fi
  return 1
}
