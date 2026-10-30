#!/usr/bin/env bash
# mutate-controls.sh — for each control in .gatekit/CONTROLS.md, break it on purpose and run the tests. The tests must fail; if they still pass, nothing really tests that control. Every file is restored afterwards, even on Ctrl-C.
#
# Usage: mutate-controls.sh [--dry-run] [--only CM-01,CM-02] [--no-baseline]
#   MUTATE_TEST_CMD   the test command (gatekit passes TEST_COMMAND from config.yaml)

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

MANIFEST=".gatekit/CONTROLS.md"
DRY=0; ONLY=""; BASELINE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --only) ONLY=",${2:-},"; shift 2 ;;
    --no-baseline) BASELINE=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { printf 'CONTROL MANIFEST: none at %s — nothing to mutate\n' "$MANIFEST"; exit 2; }

# The suite: MUTATE_TEST_CMD (gatekit passes TEST_COMMAND from config.yaml), else `npm test`.
TEST_CMD="${MUTATE_TEST_CMD:-npm test}"
# Optional faster first try per control: MUTATE_TARGET_CMD with {tests} replaced by the row's test files.
TARGET_TMPL="${MUTATE_TARGET_CMD:-}"
TARGET_TIMEOUT="${MUTATE_TARGET_TIMEOUT:-180}"
command -v timeout >/dev/null 2>&1 || TARGET_TIMEOUT=0

target_files() {   # $1 = proving-test path or glob from the manifest (from the repo root) → test files
  case "$1" in ""|"-"|"—"|"<"*) return 0 ;; esac
  local pat; pat="$(printf '%s' "$1" | sed -E 's/[.]/\\./g; s/\*/.*/g')"
  git ls-files | grep -E "^${pat}$" | sort
}
target_cmd() {   # $1 = newline-separated test files → the targeted command, or nothing
  [ -n "$TARGET_TMPL" ] && [ -n "$1" ] || return 0
  local args; args="$(printf '%s' "$1" | tr '\n' ' ')"
  printf '%s' "${TARGET_TMPL//\{tests\}/${args% }}"
}

TMP="$(mktemp -d)"
CUR_FILE=""; CUR_BAK=""
restore_current() { if [ -n "$CUR_FILE" ] && [ -f "$CUR_BAK" ]; then cp "$CUR_BAK" "$CUR_FILE"; CUR_FILE=""; fi; }
cleanup() { restore_current; rm -rf "$TMP"; }
trap 'cleanup' EXIT
SUITE_PID=""
trap '[ -n "$SUITE_PID" ] && kill "$SUITE_PID" 2>/dev/null; restore_current; printf "\ninterrupted — file restored\n" >&2; exit 130' INT TERM
run_suite() {   # $1 = log → exit status of the suite; runs in the background so a signal can reach the trap
  bash -c "$TEST_CMD" > "$1" 2>&1 & SUITE_PID=$!
  wait "$SUITE_PID"; local rc=$?; SUITE_PID=""; return $rc
}
run_targeted() {   # $1 = command, $2 = log → its exit status; 124 when it hit MUTATE_TARGET_TIMEOUT
  if [ "$TARGET_TIMEOUT" -gt 0 ] 2>/dev/null; then timeout "$TARGET_TIMEOUT" bash -c "$1" > "$2" 2>&1 & SUITE_PID=$!
  else bash -c "$1" > "$2" 2>&1 & SUITE_PID=$!; fi
  wait "$SUITE_PID"; local rc=$?; SUITE_PID=""; return $rc
}
build_broke() {   # $1 = log → 0 when the run died compiling rather than failing a test
  grep -qE 'Test suite failed to run|error TS[0-9]+|Compilation failed' "$1" && ! grep -qE 'Tests:.*[1-9][0-9]* failed' "$1"
}
TAB=$'\t'

find_def_line() {   # $1 = file, $2 = symbol → line number or empty
  local f="$1" s="$2" ln
  case "$f" in
    *)
      ln=$(grep -nE "(^|[^A-Za-z0-9_\$])function[[:space:]]*\*?[[:space:]]+${s}[[:space:]]*[(<]" "$f" | head -1 | cut -d: -f1)
      [ -n "$ln" ] || ln=$(grep -nE "(^|[^A-Za-z0-9_\$])(const|let|var)[[:space:]]+${s}[[:space:]]*(:[^=]*)?=([^=]|$)" "$f" | head -1 | cut -d: -f1)
      [ -n "$ln" ] || ln=$(grep -nE "^[[:space:]]*${s}[[:space:]]*:[[:space:]]*(async[[:space:]]*)?(function[[:space:]]*\(|\(|[A-Za-z_\$][A-Za-z0-9_\$]*[[:space:]]*=>)" "$f" | head -1 | cut -d: -f1)
      [ -n "$ln" ] || ln=$(grep -nE "^[[:space:]]*((public|private|protected|static|async|override|readonly)[[:space:]]+)*${s}[[:space:]]*(<[^>]*>)?[[:space:]]*\([^;]*$" "$f" | grep -vE '^[0-9]+:[[:space:]]*(if|for|while|switch|return|await|new)\b' | head -1 | cut -d: -f1) ;;
  esac
  printf '%s' "$ln"
}

analyse() {   # $1 = file, $2 = def line, $3 = symbol, $4 = lang (ts)
  awk -v start="$2" -v sym="$3" -v lang="$4" '
    NR < start { next }
    NR > start + 150 { exit }
    { buf = buf $0 "\n" }
    function ch(i) { return substr(buf, i, 1) }
    function is_id(c) { return c ~ /[A-Za-z0-9_$]/ }
    function skip_ws(i) { while (i <= L && ch(i) ~ /[ \t\r\n]/) i++; return i }
    function prev_nonws(i) { i--; while (i >= 1 && ch(i) ~ /[ \t\r\n]/) i--; return i }
    function match_br(i,   op, cl, d, c, q) {
      op = ch(i); cl = (op == "(" ? ")" : op == "{" ? "}" : op == "[" ? "]" : ">"); d = 0; q = ""
      for (; i <= L; i++) { c = ch(i)
        if (q != "") { if (c == q && ch(i-1) != "\\") q = ""; continue }
        if (c == "\"" || c == "\x27" || c == "`") { q = c; continue }
        if (c == op) d++; else if (c == cl) { d--; if (d == 0) return i } }
      return 0 }
    function line_of(i,   n, k) { n = 0; for (k = 1; k < i; k++) if (ch(k) == "\n") n++; return start + n }
    function col_of(i,   k) { for (k = i - 1; k >= 1; k--) if (ch(k) == "\n") break; return i - k }
    function fail(r) { printf "manual\t%s\n", r; exit }
    function done(i, params, mode, ret) { printf "ok\t%d\t%d\t%s\t%s\t%s\n", line_of(i), col_of(i), params, mode, ret; exit }
    function body_after_params(i,   j, p, c) {
      RET = ""; j = skip_ws(i)
      if (ch(j) != ":" ) { if (ch(j) == "{") return j; if (ch(j) == "=" && ch(j+1) != ">") return -1; return 0 }
      for (j = j + 1; j <= L; j++) { c = ch(j)
        if (c == "{") { p = ch(prev_nonws(j)); if (p ~ /[:|&,<(=]/) { j = match_br(j); if (j == 0) return 0; continue } RET = substr(buf, i, j - i); sub(/^[ \t\n]*:[ \t\n]*/, "", RET); sub(/[ \t\n]+$/, "", RET); return j }
        if (c == "<" || c == "(" || c == "[") { j = match_br(j); if (j == 0) return 0; continue }
        if (c == "=" && ch(j+1) != ">") return -1
        if (c == ";") return 0 }
      return 0 }
    function from_params(i, mode,   cl, body) {
      cl = match_br(i); if (cl == 0) fail("unbalanced parameter list")
      body = body_after_params(cl + 1)
      if (body == -1) fail("expression-bodied function — give it a block body")
      if (body == 0) fail("no body brace found after parameter list")
      descend(body, substr(buf, i + 1, cl - i - 1), mode, RET) }
    function from_arrow(i,   j, n, p, q, depth, c, params, start_i) {
      start_i = i; depth = 0; q = ""
      for (j = i; j <= L; j++) { c = ch(j)
        if (q != "") { if (c == q && ch(j-1) != "\\") q = ""; continue }
        if (c == "\"" || c == "\x27" || c == "`") { q = c; continue }
        if (c == "(" || c == "[" || c == "{") depth++
        if (c == ")" || c == "]" || c == "}") { depth--; if (depth < 0) fail("expression-bodied arrow — give it a block body") }
        if (c == ";" && depth == 0) fail("expression-bodied arrow — give it a block body")
        if (c == "\n" && depth == 0 && j > start_i && ch(j+1) ~ /[^ \t\n]/) fail("expression-bodied arrow — give it a block body")
        if (c == "=" && ch(j+1) == ">") {
          n = skip_ws(j + 2)
          if (ch(n) == "{") {
            p = over_type(prev_nonws(j))
            if (ch(p) == ")") { q2 = p; d = 0; for (; q2 >= 1; q2--) { if (ch(q2) == ")") d++; if (ch(q2) == "(") { d--; if (d == 0) break } } params = substr(buf, q2 + 1, p - q2 - 1) }
            else { q2 = p; while (q2 >= 1 && is_id(ch(q2))) q2--; params = substr(buf, q2 + 1, p - q2) }
            descend(n, params, "arrow", "") }
          j = n - 1 } }
      fail("no arrow body found") }
    function over_type(p,   q, c, d) {
      q = p
      while (q >= 1) { c = ch(q)
        if (c == ")" || c == ">" || c == "]" || c == "}") { d = 0; op2 = (c == ")" ? "(" : c == ">" ? "<" : c == "]" ? "[" : "{")
          for (; q >= 1; q--) { if (ch(q) == c) d++; else if (ch(q) == op2) { d--; if (d == 0) break } }
          if (q < 1) return p; q--; continue }
        if (is_id(c) || c ~ /[ \t\n.|&,?]/) { q--; continue }
        if (c == ":") { q = prev_nonws(q); return (ch(q) == ")") ? q : p }
        return p }
      return p }
    function descend(body, params, mode, ret,   k, rest) {
      k = skip_ws(body + 1); rest = substr(buf, k, 60)
      if (rest ~ /^return[ \t\n]+(async[ \t\n]+)?function[ \t\n]*\*?[ \t\n]*[A-Za-z0-9_$]*[ \t\n]*\(/) { k += index(rest, "("); from_params(k - 1, "function") }
      if (rest ~ /^return[ \t\n]+(async[ \t\n]*)?(\(|[A-Za-z_$][A-Za-z0-9_$]*[ \t\n]*=>)/) from_arrow(k + 6)
      done(body, params, mode, ret) }
    END {
      L = length(buf); if (L == 0) fail("definition line out of range")
      first = substr(buf, 1, index(buf, "\n"))
      pos = 0; p = 1
      while ((i = index(substr(first, p), sym)) > 0) { a = p + i - 1; b = a + length(sym)
        if (!is_id(substr(first, a - 1, 1)) && !is_id(substr(first, b, 1))) { pos = a; break } ; p = b }
      if (pos == 0) fail("symbol not on definition line")
      after = skip_ws(pos + length(sym))
      if (ch(after) == "<") after = skip_ws(match_br(after) + 1)
      if (ch(after) == "(") from_params(after, (first ~ /function/) ? "function" : "method")
      if (ch(after) == ":" && first !~ /(const|let|var)[ \t]/) { rhs = skip_ws(after + 1) }
      else {
        eq = 0; for (j = after; j <= L; j++) { c = ch(j); if (c == "=" && ch(j+1) != ">" && ch(j+1) != "=") { eq = j; break } if (c == "\n" && ch(j+1) ~ /[^ \t]/ && j > after) break }
        if (eq == 0) fail("no initializer found"); rhs = skip_ws(eq + 1) }
      if (substr(buf, rhs, 5) == "async") rhs = skip_ws(rhs + 5)
      if (substr(buf, rhs, 8) == "function") { k = index(substr(buf, rhs), "("); from_params(rhs + k - 1, "function") }
      from_arrow(rhs)
    }' "$1"
}

param_names() {   # $1 = raw param text → names, one per line (destructured → "{" / "[")
  printf '%s' "$1" | awk '
    { s = $0; d = 0; cur = ""; q = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (q != "") { cur = cur c; if (c == q) q = ""; continue }
        if (c == "\"" || c == "\x27" || c == "`") { q = c; cur = cur c; continue }
        if (c ~ /[(<\[{]/) d++; if (c ~ /[)>\]}]/) d--
        if (c == "," && d == 0) { emit(cur); cur = "" } else cur = cur c }
      emit(cur) }
    function emit(p) { gsub(/^[ \t\n]+|[ \t\n]+$/, "", p); if (p == "") return
      sub(/^(public|private|protected|readonly)[ \t]+/, "", p); sub(/^\.\.\./, "", p)
      if (p ~ /^[{\[]/) { print substr(p, 1, 1); return }
      sub(/[?:=].*$/, "", p); gsub(/[ \t]/, "", p); print p }'
}

infer_kind() {   # $1 = symbol, $2 = last param, $3 = rettype → kind
  local s="$1" last="$2" ret="$3" ls
  ls=$(printf '%s' "$s" | tr 'A-Z' 'a-z')
  case "$last" in next|_next) echo middleware; return ;; esac
  case "$ret" in boolean|Boolean|*"<boolean>"*|*"<Boolean>"*) echo decision; return ;; esac
  case "$s" in can[A-Z]*|is[A-Z]*|has[A-Z]*|allow*|permit*|authoriz*|authoris*|check*) echo decision; return ;; esac
  case "$s" in *Can[A-Z]*|*Is[A-Z]*|*Has[A-Z]*|*Allow*|*Permit*|*Authoriz*|*Authoris*|*Check*) echo decision; return ;; esac
  case "$ls" in *scope*|*tenant*|*owner*|*filter*|*where*) echo scope; return ;; esac
  case "$ls" in *redact*|*sanitiz*|*sanitis*|*mask*|*strip*|*scrub*) echo redact; return ;; esac
  echo noop
}

ROWS_TSV="$TMP/rows"; : > "$ROWS_TSV"
PLACEHOLDERS=0
while IFS= read -r line; do
  case "$line" in "| CM-"*) : ;; *) continue ;; esac
  id=$(  printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')
  name=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
  impl=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$4); gsub(/`/,"",$4); print $4}')
  test_g=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$6); gsub(/`/,"",$6); print $6}')
  note=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$7); print $7}')
  case "$impl" in ""|"-"|"—"|"<"*) PLACEHOLDERS=$((PLACEHOLDERS + 1)); continue ;; esac
  [ -n "$ONLY" ] && case "$ONLY" in *",$id,"*) : ;; *) continue ;; esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$impl" "$note" "$test_g" >> "$ROWS_TSV"
done < "$MANIFEST"

if [ ! -s "$ROWS_TSV" ]; then
  if [ -n "$ONLY" ]; then printf 'no manifest rows match --only %s\n' "${ONLY//,/ }"; exit 1; fi
  printf 'CONTROL MANIFEST: %s placeholder row(s), 0 controls declared — nothing to mutate\n' "$PLACEHOLDERS"; exit 2
fi

printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'MUTATE CONTROLS %s\n' "$( [ "$DRY" -eq 1 ] && printf '(dry-run)' )"
printf 'suite: %s\n' "$TEST_CMD"
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

T0=$SECONDS
if [ "$DRY" -eq 0 ] && [ "$BASELINE" -eq 1 ]; then
  printf 'baseline (unmutated) … '
  if run_suite "$TMP/baseline.log"; then printf 'GREEN (%ss)\n' "$((SECONDS - T0))"
  else printf 'RED\n  the suite is already red before any mutation — fix that first; nothing can be proven against a red suite\n'
       tail -20 "$TMP/baseline.log" | sed 's/^/  │ /'; exit 1; fi
fi

TABLE="$TMP/table"; : > "$TABLE"
NOT_PROVEN=""; MANUAL=""; TIMED_OUT=""; N=0; N_TARGETED=0; N_FALLBACK=0
while IFS="$TAB" read -r id name impl note test_g; do
  N=$((N + 1))
  file="${impl%%:*}"; sym="${impl##*:}"
  lang=ts
  kind=""; stmt=""; stmt_bad=""
  case "$note" in
    *mutate:stmt=*) stmt=$(printf '%s' "$note" | sed -E 's/.*mutate:stmt=//; s/[[:space:]]+$//'); case "$stmt" in *';') : ;; *) stmt="${stmt};" ;; esac; kind="stmt"
                    o=$(printf '%s' "$stmt" | tr -cd '(' | wc -c); c=$(printf '%s' "$stmt" | tr -cd ')' | wc -c)
                    ob=$(printf '%s' "$stmt" | tr -cd '{' | wc -c); cb=$(printf '%s' "$stmt" | tr -cd '}' | wc -c)
                    if [ "$o" -ne "$c" ] || [ "$ob" -ne "$cb" ]; then stmt_bad="unbalanced brackets in mutate:stmt (a '|' in the cell truncates it — use ?? instead of ||)"; else stmt_bad=""; fi ;;
    *mutate:replace=*) kind="replace"; rep=$(printf '%s' "$note" | sed -E 's/.*mutate:replace=//; s/[[:space:]]+$//')
                    rep_from="${rep%% ~> *}"; rep_to="${rep#* ~> }"
                    if [ "$rep_from" = "$rep" ] || [ -z "$rep_from" ]; then stmt_bad="mutate:replace needs '<exact source> ~> <replacement>'"; fi ;;
    *mutate:*) kind=$(printf '%s' "$note" | sed -E 's/.*mutate:([a-z]+).*/\1/') ;;
  esac

  if [ ! -f "$file" ]; then
    printf '| %s | %s | — | — | ✗ unlocatable: file missing |\n' "$id" "$name" >> "$TABLE"; MANUAL="$MANUAL $id"; continue
  fi
  def=$(find_def_line "$file" "$sym")
  if [ -z "$def" ]; then
    printf '| %s | %s | — | — | ✗ unlocatable: %s not defined in %s |\n' "$id" "$name" "$sym" "$file" >> "$TABLE"; MANUAL="$MANUAL $id"; continue
  fi
  res=$(analyse "$file" "$def" "$sym" "$lang" | awk '{ if (NR > 1) printf " "; printf "%s", $0 } END { print "" }')
  status="${res%%${TAB}*}"
  if [ "$status" != "ok" ]; then
    printf '| %s | %s | %s:%s | — | ✗ manual: %s |\n' "$id" "$name" "$file" "$def" "${res#*${TAB}}" >> "$TABLE"; MANUAL="$MANUAL $id"; continue
  fi
  bline=$(printf '%s' "$res" | cut -f2); bcol=$(printf '%s' "$res" | cut -f3)
  params=$(printf '%s' "$res" | cut -f4); mode=$(printf '%s' "$res" | cut -f5); ret=$(printf '%s' "$res" | cut -f6)
  names=$(param_names "$params"); first=$(printf '%s\n' "$names" | head -1); last=$(printf '%s\n' "$names" | tail -1)
  [ -n "$kind" ] || kind=$(infer_kind "$sym" "$last" "$ret")

  mutation=""; reason=""
  {
    case "$kind" in
      stmt)       if [ -n "$stmt_bad" ]; then reason="$stmt_bad"; else mutation="$stmt"; fi ;;
      middleware) case "$last" in next|_next) mutation="return ${last}();" ;; *) mutation="return next();" ;; esac ;;
      decision)   mutation="return true;" ;;
      scope|redact)
        case "$first" in
          options|opts|_options) mutation="return;" ;;
          ""|"{"|"[") if [ "$mode" = "function" ] || [ "$mode" = "method" ]; then mutation="return arguments[0];"; else reason="first parameter is destructured/absent in an arrow — add mutate:noop or name the parameter"; fi ;;
          *) mutation="return ${first};" ;;
        esac ;;
      noop) mutation="return;" ;;
      escalate)
        upar=""; for n in $names; do case "$n" in user|caller|actor|currentUser) upar="$n"; break ;; esac; done
        if [ -n "$upar" ]; then mutation="${upar} = { ...${upar}, role: 'admin' } as any;"
        else reason="escalate needs a parameter named user/caller/actor/currentUser"; fi ;;
      replace) if [ -n "$stmt_bad" ]; then reason="$stmt_bad"; else mutation="${rep_from} ~> ${rep_to}"; fi ;;
      *) reason="unknown mutate kind '$kind' (middleware|decision|scope|redact|noop|escalate|replace)" ;;
    esac
  }
  if [ -n "$reason" ]; then
    printf '| %s | %s | %s:%s (%s) | — | ✗ manual: %s |\n' "$id" "$name" "$file" "$bline" "$kind" "$reason" >> "$TABLE"; MANUAL="$MANUAL $id"; continue
  fi

  indent=$(sed -n "${bline}p" "$file" | sed -E 's/^([[:space:]]*).*/\1/')"  "
  MUT="$TMP/mut.$N"; BAK="$TMP/bak.$N"; cp "$file" "$BAK"
  if [ "$kind" = "replace" ]; then
    hit=$(REP_FROM="$rep_from" awk -v a="$def" 'NR>=a && NR<=a+200 && index($0, ENVIRON["REP_FROM"]) { print NR; exit }' "$BAK")
    if [ -z "$hit" ]; then
      printf '| %s | %s | %s:%s (replace) | — | ✗ manual: replace text not found within 200 lines of %s |\n' "$id" "$name" "$file" "$def" "$sym" >> "$TABLE"; MANUAL="$MANUAL $id"; continue
    fi
    REP_FROM="$rep_from" REP_TO="$rep_to" awk -v h="$hit" 'NR==h { i=index($0, ENVIRON["REP_FROM"]); $0=substr($0,1,i-1) ENVIRON["REP_TO"] substr($0,i+length(ENVIRON["REP_FROM"])) } { print }' "$BAK" > "$MUT"
    bline=$hit; ins1=""; ins2="$(sed -n "${hit}p" "$MUT")"; loc="${file}:${hit}"
  else
  ins1="${indent}// @ts-ignore -- mutate-controls: ${kind}"; ins2="${indent}if (true as boolean) ${mutation}"
  awk -v ln="$bline" -v col="$bcol" -v i1="$ins1" -v i2="$ins2" '
    NR != ln { print; next }
    { head = substr($0, 1, col); tail = substr($0, col + 1)
      print head; if (i1 != "") print i1; print i2
      if (tail ~ /[^ \t\r]/) print tail }' "$BAK" > "$MUT"
  if [ -n "$ins1" ]; then loc="${file}:$((bline + 2))"; else loc="${file}:$((bline + 1))"; fi
  fi

  if [ "$DRY" -eq 1 ]; then
    printf '\n%s  %s  →  %s   [%s, %s]\n' "$id" "$name" "$impl" "$kind" "$mode"
    from=$((bline - 2)); [ "$from" -lt 1 ] && from=1
    to=$((bline + 4))
    awk -v a="$from" -v b="$to" -v i1="$ins1" -v i2="$ins2" 'NR >= a && NR <= b { mark = ($0 == i2 || (i1 != "" && $0 == i1)) ? "+" : " "; printf "  %s %4d  %s\n", mark, NR, $0 }' "$MUT"
    printf '| %s | %s | %s → `%s` | — | dry-run |\n' "$id" "$name" "$kind" "$mutation" >> "$TABLE"
    continue
  fi

  CUR_FILE="$file"; CUR_BAK="$BAK"; cp "$MUT" "$file"
  t1=$SECONDS; printf '%s %s … ' "$id" "$sym"
  tcmd="$(target_cmd "$(target_files "$test_g")")"; decided=""; tag=""
  if [ -n "$tcmd" ]; then
    N_TARGETED=$((N_TARGETED + 1))
    if run_targeted "$tcmd" "$TMP/run.$N.log"; then trc=0; else trc=$?; fi
    if [ "$trc" -eq 124 ] && [ "$TARGET_TIMEOUT" -gt 0 ]; then decided="timeout"
    elif [ "$trc" -ne 0 ] && ! build_broke "$TMP/run.$N.log"; then decided="red"; tag=" (own test)"
    fi
  fi
  if [ -z "$decided" ]; then
    [ -n "$tcmd" ] && N_FALLBACK=$((N_FALLBACK + 1)) && tag=" (full suite)"
    if run_suite "$TMP/run.$N.log"; then rc=0; else rc=$?; fi
  fi
  restore_current
  el=$((SECONDS - t1))
  if [ "$decided" = "timeout" ]; then
    suite="TIMED OUT"; verdict="✗ NOT PROVEN — own test ran past ${TARGET_TIMEOUT}s"; TIMED_OUT="$TIMED_OUT $id"; NOT_PROVEN="$NOT_PROVEN $id"
  elif [ "$decided" = "red" ]; then
    suite="RED${tag}"; verdict="✓ proven"
  elif [ "$rc" -eq 0 ]; then
    suite="GREEN"; verdict="✗ NOT PROVEN"; NOT_PROVEN="$NOT_PROVEN $id"
  elif build_broke "$TMP/run.$N.log"; then
    suite="RED (build error)"; verdict="✗ NOT PROVEN — mutation broke the build, no test failed"; NOT_PROVEN="$NOT_PROVEN $id"
  else
    suite="RED${tag}"
    if [ -n "$tcmd" ]; then verdict="✓ proven — by another test; the named proving test missed it"; else verdict="✓ proven"; fi
  fi
  printf '%s (%ss)\n' "$suite" "$el"
  printf '| %s | %s | %s → `%s` @ %s | %s | %s |\n' "$id" "$name" "$kind" "$mutation" "$loc" "$suite" "$verdict" >> "$TABLE"
done < "$ROWS_TSV"

printf '\n| id | control | mutation | suite | verdict |\n|---|---|---|---|---|\n'
cat "$TABLE"
printf '\n%s control(s) · elapsed %ss' "$N" "$((SECONDS - T0))"
[ "$PLACEHOLDERS" -eq 0 ] || printf ' · %s placeholder row(s) ignored' "$PLACEHOLDERS"
[ "$N_TARGETED" -eq 0 ] || printf ' · %s run against their own test first (%s needed the full suite)' "$N_TARGETED" "$N_FALLBACK"
printf '\n'
rc=0
[ -z "$TIMED_OUT" ] || printf 'TIMED OUT:%s — the proving test ran past %ss under mutation (MUTATE_TARGET_TIMEOUT)\n' "$TIMED_OUT" "$TARGET_TIMEOUT"
if [ -n "$NOT_PROVEN" ]; then printf 'NOT PROVEN:%s — the suite stays green with the control disabled; these tests have no teeth\n' "$NOT_PROVEN"; rc=1; fi
if [ -n "$MANUAL" ]; then printf 'MANUAL / UNLOCATABLE:%s — mutate by hand or fix the manifest row (add mutate:<kind> to the note)\n' "$MANUAL"; rc=1; fi
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
exit $rc
