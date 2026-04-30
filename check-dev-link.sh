#!/usr/bin/env bash
# check-dev-link.sh — Verify the rex-desktop WoW dev install is wired
# correctly so /reload picks up code changes from this repo.
#
# Failure modes this catches:
#   - AddOns/GuildBankLedger replaced by a regular directory
#     (silent stale-load regression: WoW loads the copied files,
#     not whatever is currently in the repo)
#   - Symlink points to a different repo / clone / snapshot
#   - Libs/ missing from the repo (addon would fail to load with
#     LibStub etc unresolved)
#   - VERSION file and .toc Version disagree (in-game version label lies)
#
# Exit codes:
#   0  everything OK, or not on rex-desktop (clean skip)
#   1  one or more checks failed (message printed to stderr)
#
# Usage:  bash check-dev-link.sh

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ADDONS_DIR="/c/Program Files (x86)/World of Warcraft/_retail_/Interface/AddOns"
LINK_PATH="$ADDONS_DIR/GuildBankLedger"

# Off-machine clean skip. rex-chromebook, CI, and any other host without
# the retail WoW install at the standard path falls through here.
if [ ! -d "$ADDONS_DIR" ]; then
    echo "Not on rex-desktop (no $ADDONS_DIR) — skipping dev-link check."
    exit 0
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# 1. Must be a symlink. This is the regression we hit on 2026-04-27 —
#    the link had been replaced by a real directory containing copied
#    (stale) addon files, so WoW silently loaded old code regardless of
#    edits to the repo.
if [ ! -L "$LINK_PATH" ]; then
    if [ -d "$LINK_PATH" ]; then
        cat <<EOF >&2
FAIL: $LINK_PATH exists as a regular directory, not a symlink.
WoW will load whatever stale code is in that directory, ignoring the repo.

Repair recipe (with the bank closed in WoW, ideally with WoW shut down):
  1. mv "$LINK_PATH/Libs" "$REPO_DIR/Libs"   # gitignored, needed at runtime
  2. rm -rf "$LINK_PATH"
  3. cmd //c "mklink /D \"$(cygpath -w "$LINK_PATH")\" \"$(cygpath -w "$REPO_DIR")\""
  4. bash check-dev-link.sh   # confirm
EOF
        exit 1
    fi
    fail "$LINK_PATH does not exist. See ~/.claude/projects/.../memory/reference_guildbankledger_deploy.md for the original setup."
fi

# 2. Symlink must target THIS repo. Comparing VERSION file contents is
#    a content-based check that survives MSYS path / Windows path /
#    trailing slash differences in readlink output.
if ! cmp -s "$LINK_PATH/VERSION" "$REPO_DIR/VERSION" 2>/dev/null; then
    LINK_VER="$(cat "$LINK_PATH/VERSION" 2>/dev/null || echo '<missing>')"
    REPO_VER="$(cat "$REPO_DIR/VERSION")"
    fail "Symlink target's VERSION ($LINK_VER) differs from the repo's VERSION ($REPO_VER). The link may point to a different clone or to a stale snapshot."
fi

# 3. Libs/ must exist in the repo (gitignored runtime requirement).
if [ ! -d "$REPO_DIR/Libs" ]; then
    fail "$REPO_DIR/Libs is missing. WoW will fail to load the addon (LibStub etc unresolved). Run: bash fetch-libs.sh"
fi

# 4. VERSION and .toc Version must agree, otherwise the in-game version
#    label lies about what code is running.
VERSION_FILE="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
TOC_VERSION="$(grep '^## Version:' "$REPO_DIR/GuildBankLedger.toc" | sed 's/^## Version:[[:space:]]*//' | tr -d '[:space:]')"
if [ "$VERSION_FILE" != "$TOC_VERSION" ]; then
    fail "VERSION ($VERSION_FILE) and GuildBankLedger.toc Version ($TOC_VERSION) disagree — the in-game version label will lie."
fi

echo "OK: $LINK_PATH is a symlink"
echo "OK: link target's VERSION matches repo VERSION ($VERSION_FILE)"
echo "OK: Libs/ present in repo"
echo "OK: VERSION and .toc agree"
