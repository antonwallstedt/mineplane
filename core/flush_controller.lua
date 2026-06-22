--- Cubernetes controller that periodically flushes a set of registered TSDBs.
--- Intended to run as one coroutine inside parallel.waitForAll.
---
--- Usage:
---   local fc = FlushController.new(ctx, 60)
---   fc:register(tsdb_fuel):register(tsdb_entities)
---   parallel.waitForAll(function() fc:run() end, ...)

local FlushController = {}
FlushController.__index = FlushController

--- @param ctx             table   context with { os: { sleep, epoch } }
--- @param interval_seconds number  how often to flush, in seconds
--- @return FlushController
function FlushController.new(ctx, interval_seconds)
  assert(type(ctx) == "table" and type(ctx.os) == "table", "ctx.os is required")
  assert(
    type(interval_seconds) == "number" and interval_seconds > 0,
    "interval_seconds must be a positive number"
  )
  local self = setmetatable({}, FlushController)
  self._ctx = ctx
  self._interval_seconds = interval_seconds
  self._tsdbs = {}
  return self
end

--- Register a TSDB to be flushed each cycle.
--- @param tsdb  Tsdb
--- @return FlushController  self, for chaining
function FlushController:register(tsdb)
  table.insert(self._tsdbs, tsdb)
  return self
end

--- Execute one flush cycle: sleep for the interval, then flush all TSDBs.
--- Separated from run() so it can be called directly in tests.
--- @return number  the timestamp passed to each tsdb:flush (epoch seconds)
function FlushController:step()
  self._ctx.os.sleep(self._interval_seconds)
  local now = self._ctx.os.epoch("utc") / 1000
  for _, tsdb in ipairs(self._tsdbs) do
    tsdb:flush(now)
  end
  return now
end

--- Self-restarting loop with exponential backoff. Pass to parallel.waitForAll.
--- On error in step(), sleeps for backoff seconds before retrying.
--- Backoff doubles on each consecutive failure, capped at 60 seconds.
function FlushController:run()
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

return FlushController
