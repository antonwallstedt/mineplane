-- Mineplane dev bootstrap — run this on every computer in CraftOS-PC.
-- Sets up the /project require path, creates config.lua interactively,
-- then launches startup.lua.
--
-- Usage:
--   /project/computers/bootstrap.lua

local PROJECT = "/project"

-- Wire project modules into require so startup.lua can find them.
package.path = PROJECT .. "/?.lua;"
            .. PROJECT .. "/?/init.lua;"
            .. (package.path or "")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function ask(prompt, default)
  io.write(prompt)
  if default then io.write(" [" .. tostring(default) .. "]") end
  io.write(": ")
  local line = io.read()
  if line == nil or line == "" then return default end
  return line
end

local function ask_choice(prompt, choices)
  while true do
    io.write(prompt .. " (" .. table.concat(choices, "/") .. "): ")
    local line = io.read()
    if line then
      line = line:lower()
      for _, c in ipairs(choices) do
        if line == c then return c end
      end
    end
    print("  Please enter one of: " .. table.concat(choices, ", "))
  end
end

-- ── check existing config ─────────────────────────────────────────────────────

if fs.exists("config.lua") then
  print("config.lua already exists on this computer.")
  local choice = ask_choice("Use it or reconfigure?", { "use", "reconfigure" })
  if choice == "use" then
    print("Using existing config.lua.")
    local chunk, err = loadfile(PROJECT .. "/computers/startup.lua", "t", _ENV)
    if not chunk then error(err) end
    chunk()
    return
  end
end

-- ── interactive setup ─────────────────────────────────────────────────────────

print("")
print("Mineplane computer setup")
print("------------------------")
print("Computer ID: " .. os.getComputerID())
print("")

local role = ask_choice("Role", { "master", "worker" })

local label = ask(
  "Label",
  os.getComputerLabel() or (role .. "-" .. os.getComputerID())
)

local cfg = {
  role             = role,
  label            = label,
  heartbeat_interval = 15,
  scrape_interval  = 15,
  flush_interval   = 60,
  refresh_seconds  = 5,
  metrics_path     = "/mineplane/metrics",
}

if role == "master" then
  cfg.timeout_seconds  = tonumber(ask("Node timeout (s)", 45))  or 45
  cfg.eviction_seconds = tonumber(ask("Node eviction (s)", 300)) or 300
else
  cfg.labels = { type = "worker" }
end

-- ── write config.lua ──────────────────────────────────────────────────────────

local function write_config(c)
  local f = fs.open("config.lua", "w")
  f.writeLine("return {")
  f.writeLine('  role             = "' .. c.role .. '",')
  f.writeLine('  label            = "' .. c.label .. '",')
  f.writeLine('  heartbeat_interval = ' .. c.heartbeat_interval .. ',')
  f.writeLine('  scrape_interval  = ' .. c.scrape_interval .. ',')
  f.writeLine('  flush_interval   = ' .. c.flush_interval .. ',')
  f.writeLine('  refresh_seconds  = ' .. c.refresh_seconds .. ',')
  f.writeLine('  metrics_path     = "' .. c.metrics_path .. '",')
  if c.timeout_seconds  then f.writeLine('  timeout_seconds  = ' .. c.timeout_seconds  .. ',') end
  if c.eviction_seconds then f.writeLine('  eviction_seconds = ' .. c.eviction_seconds .. ',') end
  if c.labels then
    f.writeLine('  labels = { type = "worker" },')
  end
  f.writeLine("}")
  f.close()
end

write_config(cfg)
print("")
print("config.lua written.")
print("")

-- ── attach modem ─────────────────────────────────────────────────────────────

local has_modem = false
for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "modem" then
    has_modem = true; break
  end
end

if not has_modem then
  print("No modem found. Run:  attach left modem")
  print("Then re-run this script.")
  return
end

-- ── launch ────────────────────────────────────────────────────────────────────

print("Launching as " .. cfg.role .. ' "' .. cfg.label .. '"...')
print("")
local chunk, err = loadfile(PROJECT .. "/computers/startup.lua", "t", _ENV)
if not chunk then error(err) end
chunk()
