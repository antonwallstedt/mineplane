-- Mineplane startup script — deploy identically to every computer.
-- Role and options come from config.lua on each computer's own filesystem.

local function load_config()
  if not fs.exists("config.lua") then
    error("config.lua not found — copy computers/config.example.lua and fill it in")
  end
  return dofile("config.lua")
end

local function open_modem()
  local modem = peripheral.find("modem")
  if not modem then
    error("no modem attached — attach one and reboot")
  end
  local name = peripheral.getName(modem)
  if not modem.isWireless() then
    print("[mineplane] warning: modem on " .. name .. " is not wireless")
  end
  rednet.open(name)
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
  local Registry         = require("lib.registry")
  local RegistryServer   = require("core.registry_server")
  local ScrapeController = require("core.scrape_controller")
  local FlushController  = require("core.flush_controller")
  local NodeDisplay      = require("core.node_display")

  local transport = make_transport()
  local ctx       = make_ctx()
  local registry  = Registry.new({
    timeout_seconds  = config.timeout_seconds,
    eviction_seconds = config.eviction_seconds,
  })
  local server = RegistryServer.new(ctx, transport, registry, {
    master_id = os.getComputerID(),
  })

  local metrics_path = config.metrics_path or "/mineplane/metrics"
  local scraper = ScrapeController.new(ctx, config.scrape_interval or 15, {
    fs        = fs,
    base_path = metrics_path,
  })
  scraper:register({
    name    = "node_count",
    collect = function(_, _) return #registry:nodes() end,
  })
  scraper:register({
    name    = "ready_count",
    collect = function(_, _) return #registry:ready_nodes() end,
  })

  local flusher = FlushController.new(ctx, config.flush_interval or 60)
  for _, tsdb in ipairs(scraper:tsdbs()) do
    flusher:register(tsdb)
  end

  local mon = peripheral.find("monitor")
  if not mon then
    print("[mineplane] warning: no monitor found, display disabled")
  end
  local node_display = mon and NodeDisplay.new(ctx, mon, registry, {
    refresh_seconds = config.refresh_seconds or 5,
  })

  print("[mineplane] controlplane started, id=" .. os.getComputerID())

  -- Add new long-running subsystems here as the stack grows.
  parallel.waitForAll(
    function() server:run()  end,
    function() scraper:run() end,
    function() flusher:run() end,
    function() if node_display then node_display:run() end end
  )
end

-- ── worker ────────────────────────────────────────────────────────────────────

local function run_worker(config)
  local NodeAgent        = require("core.node_agent")
  local ScrapeController = require("core.scrape_controller")
  local FlushController  = require("core.flush_controller")

  assert(
    type(config.node) == "string" and config.node ~= "",
    "config.node is required for workers — set it in config.lua"
  )

  local transport = make_transport()
  local ctx       = make_ctx()
  local label     = config.label or os.getComputerLabel() or ("computer-" .. os.getComputerID())
  local agent     = NodeAgent.new(ctx, os.getComputerID(), transport, {
    label            = label,
    node             = config.node,
    labels           = config.labels,
    interval_seconds = config.heartbeat_interval,
  })

  local metrics_path = config.metrics_path or "/mineplane/metrics"
  local scraper = ScrapeController.new(ctx, config.scrape_interval or 15, {
    fs        = fs,
    base_path = metrics_path,
  })

  -- collectors.lua on this computer registers local peripheral metrics.
  -- Return a list of collector specs: { { name, collect, ... }, ... }
  if fs.exists("collectors.lua") then
    local collectors = dofile("collectors.lua")
    for _, spec in ipairs(collectors) do
      scraper:register(spec)
    end
  end

  local flusher = FlushController.new(ctx, config.flush_interval or 60)
  for _, tsdb in ipairs(scraper:tsdbs()) do
    flusher:register(tsdb)
  end

  print("[mineplane] worker started: " .. config.node .. "/" .. label)

  -- Add new long-running subsystems here as the stack grows.
  parallel.waitForAll(
    function() agent:run()   end,
    function() scraper:run() end,
    function() flusher:run() end
  )
end

-- ── boot ──────────────────────────────────────────────────────────────────────

local ok, err = pcall(function()
  local config = load_config()
  open_modem()

  if config.role == "controlplane" then
    run_master(config)
  elseif config.role == "worker" then
    run_worker(config)
  else
    error("config.role must be 'controlplane' or 'worker', got: " .. tostring(config.role))
  end
end)

if not ok then
  printError("[mineplane] fatal: " .. tostring(err))
end
