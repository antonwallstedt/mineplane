--- Pure display helpers for CC monitor rendering.
--- No CC globals — testable in vanilla Lua.
--- All functions that write to a monitor take it as the first argument.

local display = {}

--- Right-pad text to exactly `width` characters.
--- Truncates with ">" if the text is longer than width.
--- @param text  string
--- @param width number
--- @return string
function display.pad(text, width)
  text = tostring(text)
  if #text > width then
    return text:sub(1, width - 1) .. ">"
  end
  return text .. string.rep(" ", width - #text)
end

--- Write coloured text at an absolute monitor position.
--- @param monitor table   CC monitor peripheral (or fake)
--- @param x       number  column (1-based)
--- @param y       number  row (1-based)
--- @param text    string
--- @param color   number  colors.X constant
function display.write_at(monitor, x, y, text, color)
  monitor.setCursorPos(x, y)
  monitor.setTextColor(color)
  monitor.write(text)
end

--- Draw a horizontal rule of dashes across a full row.
--- @param monitor table
--- @param y       number  row (1-based)
--- @param width   number  number of dashes
--- @param color   number  colors.X constant
function display.hline(monitor, y, width, color)
  display.write_at(monitor, 1, y, string.rep("-", width), color)
end

--- Format an age in seconds into a human-readable string.
---
--- Spec:
---   seconds < 60      -> "42s"
---   seconds < 3600    -> "2m14s"
---   seconds < 86400   -> "1h03m"
---   seconds >= 86400  -> "2d05h"
---
--- @param seconds number  age in seconds (non-negative)
--- @return string
function display.format_age(seconds)
  seconds = math.floor(seconds)
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%dm%02ds", m, s)
  elseif seconds < 86400 then
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    return string.format("%dh%02dm", h, m)
  else
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    return string.format("%dd%02dh", d, h)
  end
end

return display
