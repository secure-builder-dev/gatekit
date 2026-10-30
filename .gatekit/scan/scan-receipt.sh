#!/usr/bin/env bash
# scan-receipt.sh — each scanner records that it actually ran (or had nothing in scope). A scanner with no receipt counts as "did not run", never as clean.

_scan_receipt_file() {
  printf '%s/scanners-ran' "${SCAN_RECEIPT_DIR:-${RESULTS_DIR:-${SCAN_RESULTS_DIR:-.}}}"
}

scan_begin() {
  local name="$1" f; f="$(_scan_receipt_file)"
  [ -f "$f" ] || return 0
  grep -v "^${name} " "$f" > "$f.tmp" 2>/dev/null || : > "$f.tmp"
  mv -f "$f.tmp" "$f" 2>/dev/null || true
  return 0
}

_scan_record() {
  local name="$1" kind="$2" detail="${3:-}" f; f="$(_scan_receipt_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  scan_begin "$name"
  printf '%s %s %s\n' "$name" "$kind" "$detail" >> "$f"
}

scan_ran()  { _scan_record "$1" ran  "${2:-}"; }
scan_none() { _scan_record "$1" none "${2:-}"; }

scan_receipt_kind() {
  local name="$1" f; f="$(_scan_receipt_file)"
  [ -f "$f" ] || return 0
  awk -v n="$name" '$1 == n { print $2; exit }' "$f" 2>/dev/null || true
  return 0
}
