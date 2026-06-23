-- Dev autostart: attaches peripherals then boots the real startup.
-- Written to each computer's root by scripts/dev.sh.
-- Uses periphemu (CraftOS-PC only) so modems/monitors appear automatically.
--
-- Only computer 0 (controlplane) is launched by dev.sh directly.
-- It creates computers 1 and 2 as peripherals so they all share the same
-- CraftOS-PC process — required for wireless rednet to work across computers.

local function attach(side, ptype, ...)
  if periphemu then pcall(periphemu.create, side, ptype, ...) end
end

local role
do
  local ok, cfg = pcall(dofile, "config.lua")
  if ok and type(cfg) == "table" then role = cfg.role end
end

attach("left", "modem")

if role == "controlplane" then
  attach("right",      "monitor")
  attach("computer_1", "computer")
  attach("computer_2", "computer")
end

package.path = "/project/?.lua;/project/?/init.lua;" .. (package.path or "")
local chunk, err = loadfile("/project/computers/startup.lua", "t", _ENV)
if not chunk then error(err) end
chunk()
