--- Cubernetes controller that scrapes registered collectors on a fixed interval
--- and pushes results into their TSDBs.
--- Intended to run as one coroutine inside parallel.waitForAll.
---
--- Usage:
---   local sc = ScrapeController.new(ctx, 15, { fs = fs, base_path = "/data/metrics" })
---   sc:register({ name = "fuel", collect = function(ctx, now) return getFuel() end })
---   local fc = FlushController.new(ctx, 60)
---   for _, tsdb in ipairs(sc:tsdbs()) do fc:register(tsdb) end
---   parallel.waitForAll(function() sc:run() end, function() fc:run() end)

local Tsdb = require("lib.tsdb")

local DEFAULTS = {
  capacity       = 120,
  window_seconds = 60,
  retain_seconds = 3600,
  downsample     = function(...)
    local t, s = { ... }, 0
    for _, v in ipairs(t) do s = s + v end
    return s / #t
  end,
}

local ScrapeController = {}
ScrapeController.__index = ScrapeController

--- @param ctx              table   context with { os: { sleep, epoch } }
--- @param interval_seconds number  how often to scrape, in seconds
--- @param opts             table   { fs, base_path, defaults? }
--- @return ScrapeController
function ScrapeController.new(ctx, interval_seconds, opts)
  assert(type(ctx) == "table" and type(ctx.os) == "table", "ctx.os is required")
  assert(
    type(interval_seconds) == "number" and interval_seconds > 0,
    "interval_seconds must be a positive number"
  )
  assert(type(opts) == "table", "opts is required")
  assert(type(opts.fs) == "table", "opts.fs is required")
  assert(
    type(opts.base_path) == "string" and opts.base_path ~= "",
    "opts.base_path must be a non-empty string"
  )
  local self = setmetatable({}, ScrapeController)
  self._ctx = ctx
  self._interval_seconds = interval_seconds
  self._opts = opts
  self._entries = {}
  self._errors = {}
  return self
end

-- ─── internal ─────────────────────────────────────────────────────────────────

local function merge_config(collector, opts_defaults)
  local d = opts_defaults or {}
  return {
    capacity       = collector.capacity       or d.capacity       or DEFAULTS.capacity,
    window_seconds = collector.window_seconds or d.window_seconds or DEFAULTS.window_seconds,
    retain_seconds = collector.retain_seconds or d.retain_seconds or DEFAULTS.retain_seconds,
    downsample     = collector.downsample     or d.downsample     or DEFAULTS.downsample,
  }
end

-- ─── public API ───────────────────────────────────────────────────────────────

--- Register a collector. Validates the contract, builds its TSDB, stores both.
--- @param collector  table  { name, collect, downsample?, window_seconds?, retain_seconds?, capacity? }
--- @return ScrapeController  self, for chaining
function ScrapeController:register(collector)
  assert(
    type(collector.name) == "string" and collector.name ~= "",
    "collector.name must be a non-empty string"
  )
  assert(
    not collector.name:match("[/%s]"),
    "collector.name must not contain slashes or whitespace"
  )
  assert(type(collector.collect) == "function", "collector.collect must be a function")
  local config = merge_config(collector, self._opts.defaults)
  local tsdb = Tsdb.builder()
    :capacity(config.capacity)
    :window_seconds(config.window_seconds)
    :retain_seconds(config.retain_seconds)
    :downsample(config.downsample)
    :build(self._opts.fs, self._opts.base_path .. "/" .. collector.name)
  table.insert(self._entries, { collector = collector, tsdb = tsdb })
  return self
end

--- Returns all TSDBs in registration order.
--- Hand these to FlushController:register() to wire up periodic flushing.
--- @return Tsdb[]
function ScrapeController:tsdbs()
  local result = {}
  for _, entry in ipairs(self._entries) do
    table.insert(result, entry.tsdb)
  end
  return result
end

--- Execute one scrape cycle: collect all, push results, then sleep.
--- Separated from run() so it can be called directly in tests.
--- Per-collector errors are isolated — one failure does not stop others.
--- @return number  epoch-seconds timestamp shared across all pushes this cycle
function ScrapeController:step()
  local now = self._ctx.os.epoch("utc") / 1000
  for _, entry in ipairs(self._entries) do
    local ok, result = pcall(entry.collector.collect, self._ctx, now)
    if ok then
      if type(result) == "number" then
        entry.tsdb:push(now, result)
      end
    else
      local rec = self._errors[entry.collector.name]
      if not rec then
        rec = { count = 0, last_message = nil }
        self._errors[entry.collector.name] = rec
      end
      rec.count = rec.count + 1
      rec.last_message = tostring(result)
    end
  end
  self._ctx.os.sleep(self._interval_seconds)
  return now
end

--- Error table: { [collector_name] = { count, last_message } }.
--- Counts grow monotonically (Prometheus scrape_failures_total semantics).
--- @return table
function ScrapeController:errors()
  return self._errors
end

--- Self-restarting loop with exponential backoff. Pass to parallel.waitForAll.
--- Backoff applies only to controller-level panics; per-collector errors are
--- already isolated inside step().
function ScrapeController:run()
  local backoff = 1
  while true do
    local ok = pcall(self.step, self)
    if ok then
      backoff = 1
    else
      self._ctx.os.sleep(backoff)
      backoff = math.min(backoff * 2, 60)
    end
  end
end

return ScrapeController
