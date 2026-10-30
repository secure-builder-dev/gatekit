# tickets.sh — write ticket files. Sourced after common.sh.
#
# A ticket is .gatekit/records/<branch>/tickets/T-nnn.md. The gate sends any ticket without a
# windshift_id to Windshift on its next run, so tickets written here get there too.

# gk_ticket TITLE SEVERITY DONE_WHEN BODY [FOUND_BY] — write a ticket unless an open one has the same title.
gk_ticket() {
  local title="$1" severity="$2" done_when="$3" body="$4" found_by="${5:-make scans}"
  mkdir -p "$GK_REC/tickets"
  if grep -lxF "title: $title" "$GK_REC"/tickets/*.md 2>/dev/null | xargs grep -L '^status: done' 2>/dev/null | grep -q .; then
    return 0     # already ticketed and not done
  fi
  local id; id="$(gk_next_ticket_id)"
  cat > "$GK_REC/tickets/$id.md" <<EOF
---
id: $id
title: $title
branch: $GK_BRANCH
status: open
severity: $severity
found_by: $found_by
done_when: "$done_when"
windshift_id:
---

$body
EOF
  gk_say "ticket $id: $title"
}

# gk_tickets_from_dispatch — one ticket per finding still in dispatch.md after patching.
gk_tickets_from_dispatch() {
  local d="$SCAN_RESULTS_DIR/dispatch.md"
  [ -f "$d" ] || return 0
  local tmp; tmp="$(mktemp -d)"
  awk -v out="$tmp" '
    /^### / { n++; f = sprintf("%s/%03d", out, n); sub(/^### /, ""); print > (f ".title"); next }
    /^## |^---/ { f = ""; next }
    f { print >> (f ".body") }
  ' "$d"
  local t
  for t in "$tmp"/*.title; do
    [ -f "$t" ] || continue
    local title body
    title="$(cat "$t")"
    body="$(cat "${t%.title}.body" 2>/dev/null)"
    gk_ticket "Scan: $title" blocking \
      "make scans no longer reports $title" \
      "make patch could not fix this automatically (or fixing it broke the tests).

$body"
  done
  rm -rf "$tmp"
}
