# update.sh — gatekit keeps itself up to date. Sourced by .gatekit/gk before every command.
#
# What it does:
#   1. At most every 6 hours, asks GitHub for the newest gatekit release.
#   2. If it's newer than .gatekit/VERSION, downloads it, swaps in the new kit files,
#      keeps your own files (config.yaml, CONTROLS.md, records/, allowlists), and commits
#      "gatekit: update to vX.Y.Z" on your branch.
#   3. If GitHub can't be reached and gatekit hasn't confirmed it's current for 14 days, stops.
#      Under 14 days it just warns.
#
# Turn it off for one run with GATEKIT_NO_UPDATE=1 (the gatekit repo itself always skips it).

GK_STALE_DAYS=14
GK_CHECK_EVERY=$((6 * 3600))
GK_STATE="$GK_DIR/.state"          # per machine, gitignored
mkdir -p "$GK_STATE"

gk_version() { sed -nE 's/^version:[[:space:]]*//p' "$GK_DIR/VERSION"; }
gk_repo()    { sed -nE 's/^repo:[[:space:]]*//p' "$GK_DIR/VERSION"; }

# newer A B — true when version A is newer than B.
gk_newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

gk_days_since() {   # epoch seconds -> whole days ago
  echo $(( ( $(date +%s) - ${1:-0} ) / 86400 ))
}

gk_install_claude_files() {
  mkdir -p "$GK_ROOT/.claude/agents" "$GK_ROOT/.claude/skills"
  cp "$GK_DIR/agents/gatekit-gate.md" "$GK_ROOT/.claude/agents/gatekit-gate.md"
  rm -rf "$GK_ROOT/.claude/skills/implement"
  cp -R "$GK_DIR/skills/implement" "$GK_ROOT/.claude/skills/implement"
}

gk_self_update() {
  [ "${GATEKIT_NO_UPDATE:-0}" = 1 ] && return 0
  [ "${GK_UPDATED:-0}" = 1 ] && return 0
  [ -f "$GK_ROOT/.gatekit-source" ] && return 0     # this is the gatekit repo itself

  local now last_check last_ok repo cur latest tag tmp
  now=$(date +%s)
  last_check=$(cat "$GK_STATE/last-check" 2>/dev/null || echo 0)
  [ $(( now - last_check )) -lt $GK_CHECK_EVERY ] && return 0
  echo "$now" > "$GK_STATE/last-check"

  repo="$(gk_repo)"; cur="$(gk_version)"
  latest="$(curl -fsSL --max-time 15 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
            | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/p' | head -1)"

  if [ -z "$latest" ]; then
    last_ok=$(cat "$GK_STATE/last-ok" 2>/dev/null || date -j -f %Y-%m-%d "$(sed -nE 's/^released:[[:space:]]*//p' "$GK_DIR/VERSION")" +%s 2>/dev/null || date -d "$(sed -nE 's/^released:[[:space:]]*//p' "$GK_DIR/VERSION")" +%s 2>/dev/null || echo 0)
    local age; age=$(gk_days_since "$last_ok")
    rm -f "$GK_STATE/last-check"     # try again next run
    if [ "$age" -ge "$GK_STALE_DAYS" ]; then
      gk_die "can't reach GitHub to update, and gatekit hasn't been confirmed current for $age days (limit $GK_STALE_DAYS). Connect to the internet and run the command again."
    fi
    gk_say "warning: couldn't check for updates (offline?). Last confirmed current $age day(s) ago; stops at $GK_STALE_DAYS."
    return 0
  fi

  echo "$now" > "$GK_STATE/last-ok"
  gk_newer "$latest" "$cur" || return 0

  gk_say "updating $cur → $latest"
  tmp="$(mktemp -d)"
  tag="v$latest"
  if ! curl -fsSL --max-time 120 "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" | tar -xz -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"; gk_say "warning: download of $tag failed; staying on $cur"; return 0
  fi
  local new; new="$(find "$tmp" -maxdepth 2 -type d -name .gatekit | head -1)"
  [ -n "$new" ] && [ -f "$new/VERSION" ] || { rm -rf "$tmp"; gk_say "warning: $tag has no .gatekit/ folder; staying on $cur"; return 0; }

  # Your files stay. Everything else is replaced.
  local keep=(config.yaml CONTROLS.md records checkov-justifications.yaml npm-audit-allowlist.yaml .state)
  for k in "${keep[@]}"; do [ -e "$GK_DIR/$k" ] && mv "$GK_DIR/$k" "$tmp/keep-$k"; done
  rm -rf "$GK_DIR"; cp -R "$new" "$GK_DIR"
  for k in "${keep[@]}"; do [ -e "$tmp/keep-$k" ] && { rm -rf "$GK_DIR/$k"; mv "$tmp/keep-$k" "$GK_DIR/$k"; }; done
  rm -rf "$tmp"

  gk_install_claude_files
  local paths=(.gatekit ':(exclude).gatekit/records' .claude/agents/gatekit-gate.md .claude/skills/implement)
  git add -A -- "${paths[@]}"
  git commit -q -m "gatekit: update to v$latest" -- "${paths[@]}" \
    && gk_say "updated to v$latest and committed"
  export GK_UPDATED=1
  exec bash "$GK_DIR/gk" "$@"
}
