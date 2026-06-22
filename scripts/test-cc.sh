#!/usr/bin/env bash
# Run the Mineplane test suite inside CraftOS-PC headless mode.
# Requires CraftOS-PC 2.x to be installed.
#
# macOS install (the Homebrew cask has a stale checksum; use gh directly):
#   gh release download v2.8.3 --repo MCJack123/craftos2 --pattern "CraftOS-PC.dmg" --dir /tmp/craftos
#   hdiutil attach /tmp/craftos/CraftOS-PC.dmg -quiet
#   cp -r "/Volumes/CraftOS-PC/CraftOS-PC.app" /Applications/
#   hdiutil detach /Volumes/CraftOS-PC -quiet
#
# Linux: download the AppImage from the same release and make it executable.
# Windows: use the Setup.exe from the same release.
#
# Then run from the repo root:
#   bash scripts/test-cc.sh

set -euo pipefail

# Search PATH first, then the macOS app bundle location.
CRAFTOS=$(command -v craftos 2>/dev/null \
  || command -v craftos-pc 2>/dev/null \
  || { [[ -x /Applications/CraftOS-PC.app/Contents/MacOS/craftos ]] \
       && echo /Applications/CraftOS-PC.app/Contents/MacOS/craftos; } \
  || true)

if [[ -z "$CRAFTOS" ]]; then
  echo "ERROR: CraftOS-PC not found." >&2
  echo "  See scripts/test-cc.sh for install instructions." >&2
  exit 1
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Use a temp directory for the CC computer's data so we know where to find
# the results file the runner writes at /results.txt (→ computer/0/results.txt).
CC_DATA=$(mktemp -d)
trap 'rm -rf "$CC_DATA"' EXIT

# --script takes a HOST path; it executes inside CC where /project is the mount.
# The runner writes all output to /results.txt instead of using print(), which
# avoids the headless renderer dumping 19 padded terminal rows per character.
"$CRAFTOS" \
  --headless \
  --directory "$CC_DATA" \
  --mount-ro /project="$REPO_ROOT" \
  --script "$REPO_ROOT/test/cc_runner.lua" \
  > /dev/null 2>&1
EXIT_CODE=$?

RESULTS="$CC_DATA/computer/0/results.txt"
if [[ -f "$RESULTS" ]]; then
  cat "$RESULTS"
else
  echo "ERROR: results file not found at $RESULTS" >&2
  echo "  The runner may have crashed before writing output." >&2
fi

exit $EXIT_CODE
