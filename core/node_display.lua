--- Renders the node registry to a CC monitor on a fixed interval.
--- Intended to run as one coroutine inside parallel.waitForAll.
---
--- ctx shape:  { os = { epoch = function(unit), sleep = function(n) } }
--- monitor:    CC monitor peripheral handle (or fake)
--- registry:   lib/registry instance

local display = require("lib.display")

-- Fallback when running outside CC (tests in vanilla Lua).
-- In CC, colors is a global with specific bit-field values.
local colors = _G.colors or {
  white  = 1,
  yellow = 4,
  gray   = 8,
  green  = 32,
  red    = 16384,
}

local NodeDisplay = {}
NodeDisplay.__index = NodeDisplay

-- Fixed column widths; label expands to fill remaining monitor width.
local COLS_FIXED = { id = 4, status = 10, age = 8 }  -- sum = 22

local DEFAULT_REFRESH  = 5
local DEFAULT_SCALE    = 0.5

--- @param ctx      table     { os = { epoch, sleep } }
--- @param monitor  table     CC monitor peripheral
--- @param registry Registry  lib/registry instance
--- @param opts     table?    { refresh_seconds?, text_scale? }
--- @return NodeDisplay
function NodeDisplay.new(ctx, monitor, registry, opts)
  assert(type(ctx) == "table" and type(ctx.os) == "table", "ctx.os required")
  assert(type(monitor) == "table", "monitor must be a table")
  assert(type(registry) == "table", "registry must be a table")
  opts = opts or {}
  local self = setmetatable({}, NodeDisplay)
  self._ctx      = ctx
  self._monitor  = monitor
  self._registry = registry
  self._refresh  = opts.refresh_seconds or DEFAULT_REFRESH
  self._scale    = opts.text_scale      or DEFAULT_SCALE
  return self
end

-- ── rendering ─────────────────────────────────────────────────────────────────

local function render(mon, registry, now, scale)
  mon.clear()
  mon.setTextScale(scale)
  local w, _ = mon.getSize()

  -- Label column fills remaining width after fixed columns.
  local label_w = math.max(8, w - COLS_FIXED.id - COLS_FIXED.status - COLS_FIXED.age)

  local all    = registry:nodes()
  local ready  = registry:ready_nodes()
  local header = string.format("Mineplane  |  %d nodes  |  %d ready", #all, #ready)

  -- row 1: summary header
  display.write_at(mon, 1, 1, header, colors.white)

  -- row 2: separator
  display.hline(mon, 2, w, colors.gray)

  -- row 3: column headers
  local col_header = display.pad("ID",     COLS_FIXED.id)
                  .. display.pad("Label",  label_w)
                  .. display.pad("Status", COLS_FIXED.status)
                  .. display.pad("Age",    COLS_FIXED.age)
  display.write_at(mon, 1, 3, col_header, colors.yellow)

  -- rows 4+: one per node
  for i, node in ipairs(all) do
    local age   = display.format_age(math.max(0, now - node.last_seen))
    local color = node.status == "Ready" and colors.green or colors.red
    local line  = display.pad(tostring(node.id), COLS_FIXED.id)
                .. display.pad(node.label,        label_w)
                .. display.pad(node.status,        COLS_FIXED.status)
                .. display.pad(age,                COLS_FIXED.age)
    display.write_at(mon, 1, 3 + i, line, color)
  end
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Render one frame then sleep.
--- @return number  current epoch seconds
function NodeDisplay:step()
  local now = self._ctx.os.epoch("utc") / 1000
  render(self._monitor, self._registry, now, self._scale)
  self._ctx.os.sleep(self._refresh)
  return now
end

--- Self-restarting render loop with exponential backoff.
function NodeDisplay:run()
  local backoff = 1
  while true do
    local ok, err = pcall(function() self:step() end)
    if ok then
      backoff = 1
    else
      _ = err
      self._ctx.os.sleep(backoff)
      backoff = math.min(backoff * 2, 60)
    end
  end
end

return NodeDisplay
