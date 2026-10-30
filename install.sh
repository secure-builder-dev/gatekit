#!/usr/bin/env bash
# install.sh — add gatekit to the repo you're in.
#
#   curl -fsSL https://raw.githubusercontent.com/secure-builder-dev/gatekit/main/install.sh | bash
#
# It downloads the newest gatekit release, copies the .gatekit/ folder into this repo, adds one
# `include` line to your Makefile, and runs `make gatekit-init`. After that gatekit updates itself.
set -euo pipefail
REPO="secure-builder-dev/gatekit"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Run this from inside your project's git repo."; exit 1; }
cd "$root"
[ -d .gatekit ] && { echo "gatekit is already installed here. It updates itself; nothing to do."; exit 0; }
for t in curl tar git make; do command -v "$t" >/dev/null || { echo "Missing: $t"; exit 1; }; done

tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -n "$tag" ] || { echo "Couldn't find a gatekit release on github.com/$REPO."; exit 1; }
echo "Installing gatekit $tag..."

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/$REPO/archive/refs/tags/$tag.tar.gz" | tar -xz -C "$tmp"
src="$(find "$tmp" -maxdepth 2 -type d -name .gatekit | head -1)"
[ -n "$src" ] || { echo "That release has no .gatekit/ folder."; exit 1; }
cp -R "$src" .gatekit

line="include .gatekit/Makefile.gatekit"
touch Makefile
grep -qxF "$line" Makefile || printf '\n%s\n' "$line" >> Makefile

# Read answers from the keyboard even though this script came in through a pipe.
if { : < /dev/tty; } 2>/dev/null; then make gatekit-init < /dev/tty; else make gatekit-init < /dev/null; fi
