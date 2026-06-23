#!/usr/bin/env bash
# Launch a 3-computer Mineplane dev environment in CraftOS-PC.
#
#   computer 0  controlplane  (monitor on right, modem on left)
#   computer 1  worker        factory / mystical-agriculture
#   computer 2  worker        factory / fusion-reactor
#
# Writes config.lua + startup.lua to each computer's data directory,
# then opens a CraftOS-PC window for each.

set -euo pipefail

CRAFTOS="/Applications/CraftOS-PC.app/Contents/MacOS/craftos"
DATA="$HOME/Library/Application Support/CraftOS-PC/computer"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AUTOSTART="$PROJECT/computers/dev_autostart.lua"
MOUNT="--mount-rw /project=$PROJECT"

if [ ! -x "$CRAFTOS" ]; then
  echo "error: craftos not found at $CRAFTOS" >&2; exit 1
fi
if [ ! -f "$AUTOSTART" ]; then
  echo "error: computers/dev_autostart.lua not found" >&2; exit 1
fi

# ── write files for each computer ────────────────────────────────────────────

setup_computer() {
  local id="$1"
  local config="$2"
  local dir="$DATA/$id"
  mkdir -p "$dir"
  printf '%s\n' "$config" > "$dir/config.lua"
  cp "$AUTOSTART" "$dir/startup.lua"
  echo "  computer $id: ready"
}

echo "Writing computer configs..."

setup_computer 0 'return {
  role             = "controlplane",
  timeout_seconds  = 45,
  eviction_seconds = 300,
  refresh_seconds  = 5,
  scrape_interval  = 15,
  flush_interval   = 60,
  metrics_path     = "/mineplane/metrics",
}'

setup_computer 1 'return {
  role               = "worker",
  node               = "factory",
  label              = "mystical-agriculture",
  heartbeat_interval = 15,
  scrape_interval    = 15,
  flush_interval     = 60,
  metrics_path       = "/mineplane/metrics",
}'

setup_computer 2 'return {
  role               = "worker",
  node               = "factory",
  label              = "fusion-reactor",
  heartbeat_interval = 15,
  scrape_interval    = 15,
  flush_interval     = 60,
  metrics_path       = "/mineplane/metrics",
}'

# ── launch CraftOS-PC windows ─────────────────────────────────────────────────

echo ""
echo "Launching CraftOS-PC..."
echo "(computers 1 and 2 are created as peripherals by computer 0 — same process = shared rednet)"
"$CRAFTOS" --id 0 $MOUNT &

echo "Done. Computer 0 will open, then spawn windows for computers 1 and 2."
