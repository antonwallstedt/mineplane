-- Mineplane startup script — deploy identically to every computer.
-- Role and options come from config.lua on each computer's own filesystem.

local function load_config()
  if not fs.exists("config.lua") then
    error("config.lua not found — copy computers/config.example.lua and fill it in")
  end
  return dofile("config.lua")
end

local function open_modem()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then
    error("no wireless modem attached — attach one and reboot")
  end
  rednet.open(peripheral.getName(modem))
  return modem
end

local PROTOCOL = "mineplane"

local function make_transport()
  return {
    send      = function(id, msg) rednet.send(id, msg, PROTOCOL) end,
    broadcast = function(msg)     rednet.broadcast(msg, PROTOCOL) end,
    receive   = function(timeout) return rednet.receive(PROTOCOL, timeout) end,
  }
end

local function make_ctx()
  return {
    os = {
      epoch = function(unit) return os.epoch(unit) end,
      sleep = function(n)    return os.sleep(n) end,
    },
  }
end

-- ── master ────────────────────────────────────────────────────────────────────

local function run_master(config)
  local Registry       = require("lib.registry")
  local RegistryServer = require("core.registry_server")

  local transport = make_transport()
  local ctx       = make_ctx()
  local registry  = Registry.new({
    timeout_seconds  = config.timeout_seconds,
    eviction_seconds = config.eviction_seconds,
  })
  local server = RegistryServer.new(ctx, transport, registry, {
    master_id = os.getComputerID(),
  })

  print("[mineplane] master started, id=" .. os.getComputerID())

  -- TODO: add subsystems here as the stack grows.
  -- Each long-running loop gets its own entry in waitForAll.
  -- Example once ScrapeController exists:
  --   local scraper = ScrapeController.new(ctx, { ... })
  --   scraper:register("energy", { collect = ..., ... })
  --
  parallel.waitForAll(
    function() server:run() end
  )
end

-- ── worker ────────────────────────────────────────────────────────────────────

local function run_worker(config)
  local NodeAgent = require("core.node_agent")

  local transport = make_transport()
  local ctx       = make_ctx()
  local label     = config.label or os.getComputerLabel() or ("node-" .. os.getComputerID())
  local agent     = NodeAgent.new(ctx, os.getComputerID(), transport, {
    label            = label,
    labels           = config.labels,
    interval_seconds = config.heartbeat_interval,
  })

  print("[mineplane] worker started, label=" .. label)

  -- TODO: add worker subsystems here (local collectors, display loops, etc.).
  parallel.waitForAll(
    function() agent:run() end
  )
end

-- ── boot ──────────────────────────────────────────────────────────────────────

local ok, err = pcall(function()
  local config = load_config()
  open_modem()

  if config.role == "master" then
    run_master(config)
  elseif config.role == "worker" then
    run_worker(config)
  else
    error("config.role must be 'master' or 'worker', got: " .. tostring(config.role))
  end
end)

if not ok then
  printError("[mineplane] fatal: " .. tostring(err))
end
