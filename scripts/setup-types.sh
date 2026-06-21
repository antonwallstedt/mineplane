#!/usr/bin/env bash
# Pulls CC:Tweaked LuaCATS type stubs into .luals/cc-tweaked.
# Run once after cloning. Output is gitignored.
set -euo pipefail

DEST=".luals/cc-tweaked"
REPO="https://github.com/CC-Tweaked/CC-Tweaked.git"
BRANCH="mc-1.21.x"
SPARSE_DIR="doc/stub"

if [ -d "$DEST" ]; then
  echo "✓ $DEST already exists, skipping."
  exit 0
fi

echo "Fetching CC:Tweaked LuaCATS stubs (sparse clone)…"
git clone \
  --filter=blob:none \
  --sparse \
  --depth=1 \
  --branch "$BRANCH" \
  "$REPO" \
  "$DEST.tmp"

(cd "$DEST.tmp" && git sparse-checkout set "$SPARSE_DIR")

mkdir -p "$DEST"
cp -r "$DEST.tmp/$SPARSE_DIR/." "$DEST/"
rm -rf "$DEST.tmp"

echo "✓ Stubs written to $DEST"
echo "  Restart LuaLS / reload VS Code window to pick them up."
