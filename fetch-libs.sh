#!/usr/bin/env bash
# fetch-libs.sh — Download Ace3 and supporting libraries for local development.
# Libs/ is gitignored; this script populates it from GitHub mirrors.
# Idempotent: skips libraries that already exist.
#
# Usage:  bash fetch-libs.sh

set -euo pipefail

LIBS_DIR="Libs"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$LIBS_DIR"

# ---------- Ace3 monorepo (one clone, many subdirectories) ----------

ACE3_LIBS=(
    CallbackHandler-1.0
    AceAddon-3.0
    AceDB-3.0
    AceDBOptions-3.0
    AceConsole-3.0
    AceEvent-3.0
    AceGUI-3.0
    AceConfig-3.0
    AceConfigDialog-3.0
    AceConfigCmd-3.0
)

need_ace3=false
for lib in "${ACE3_LIBS[@]}"; do
    if [ ! -d "$LIBS_DIR/$lib" ]; then
        need_ace3=true
        break
    fi
done

if $need_ace3; then
    echo "Cloning Ace3 monorepo..."
    git clone --depth 1 --quiet https://github.com/BigWigsMods/Ace3.git "$TEMP_DIR/Ace3"
    for lib in "${ACE3_LIBS[@]}"; do
        if [ ! -d "$LIBS_DIR/$lib" ]; then
            if [ -d "$TEMP_DIR/Ace3/$lib" ]; then
                cp -r "$TEMP_DIR/Ace3/$lib" "$LIBS_DIR/$lib"
                echo "  Installed $lib"
            else
                echo "  WARNING: $lib not found in Ace3 repo"
            fi
        else
            echo "  Skipped $lib (already exists)"
        fi
    done
else
    echo "All Ace3 libraries already present."
fi

# ---------- Standalone libraries ----------

install_standalone() {
    local name="$1"
    local repo="$2"
    local subdir="${3:-}"  # optional subdirectory within the clone

    if [ -d "$LIBS_DIR/$name" ]; then
        echo "  Skipped $name (already exists)"
        return
    fi

    echo "  Cloning $name..."
    git clone --depth 1 --quiet "https://github.com/$repo.git" "$TEMP_DIR/$name"

    if [ -n "$subdir" ]; then
        cp -r "$TEMP_DIR/$name/$subdir" "$LIBS_DIR/$name"
    else
        cp -r "$TEMP_DIR/$name" "$LIBS_DIR/$name"
        rm -rf "$LIBS_DIR/$name/.git"
    fi
}

echo "Installing standalone libraries..."
install_standalone "LibStub"            "BigWigsMods/LibStub"
install_standalone "LibDBIcon-1.0"      "BigWigsMods/LibDBIcon-1.0"     "LibDBIcon-1.0"
install_standalone "LibDataBroker-1.1"  "tekkub/libdatabroker-1-1"
install_standalone "LibSharedMedia-3.0" "BigWigsMods/LibSharedMedia-3.0" "LibSharedMedia-3.0"

echo ""
echo "Done. All libraries installed to $LIBS_DIR/"
echo "Listing:"
ls -1 "$LIBS_DIR/"
