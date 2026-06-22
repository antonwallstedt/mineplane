--- Unified hot+cold TSDB for a single metric.
--- Coordinates a RingBuffer (hot layer) and a ColdStore (cold layer).
---
--- Preferred construction via builder:
---   local tsdb = Tsdb.builder()
---     :capacity(120)
---     :window_seconds(60)
---     :retain_seconds(3600)
---     :downsample(math.max)
---     :build(fs, "/data/metrics/fuel_level")

local RingBuffer = require("lib.ring_buffer")
local ColdStore = require("lib.cold_store")

-- ─── Tsdb ─────────────────────────────────────────────────────────────────────

local Tsdb = {}
Tsdb.__index = Tsdb

--- Direct construction — prefer Tsdb.builder() for normal use.
--- @param ring_buffer  RingBuffer
--- @param cold_store   ColdStore
--- @return Tsdb
function Tsdb.new(ring_buffer, cold_store)
  assert(ring_buffer ~= nil, "ring_buffer is required")
  assert(cold_store ~= nil, "cold_store is required")
  local self = setmetatable({}, Tsdb)
  self._ring_buffer = ring_buffer
  self._cold_store = cold_store
  return self
end

--- Push a new sample into the hot layer.
--- @param time   number  epoch seconds
--- @param value  number
--- @return Tsdb  self, for chaining
function Tsdb:push(time, value)
  self._ring_buffer:push(time, value)
  return self
end

--- Flush hot samples to cold storage and run compaction.
--- Called by the external timer coroutine — never called internally.
--- Order is load-bearing: flush before compact (so new samples are included
--- in this compaction window), clear after flush (so no samples are lost).
--- @param now_seconds  number  current epoch seconds (injected for testability)
function Tsdb:flush(now_seconds)
  self._cold_store:flush(self._ring_buffer:all())
  self._cold_store:compact_and_evict(now_seconds)
  self._ring_buffer:clear()
end

--- Query samples in [from, to] across hot and cold layers, oldest-first.
--- Cold samples are always older than hot (ring buffer is cleared on flush),
--- so the result is cold results followed by in-range hot results.
--- @param from  number  epoch seconds, inclusive
--- @param to    number  epoch seconds, inclusive
--- @return {time:number, value:number}[]
function Tsdb:query(from, to)
  local result = self._cold_store:query(from, to)
  for sample in self._ring_buffer:iter() do
    if sample.time >= from and sample.time <= to then
      table.insert(result, sample)
    end
  end
  return result
end

-- ─── Builder ──────────────────────────────────────────────────────────────────

local Builder = {}
Builder.__index = Builder

--- @return Builder
function Tsdb.builder()
  return setmetatable({}, Builder)
end

--- @param n integer  ring buffer capacity (number of raw samples to keep hot)
function Builder:capacity(n)
  self._capacity = n
  return self
end

--- @param n number  tier1 bucket width in seconds
function Builder:window_seconds(n)
  self._window_seconds = n
  return self
end

--- @param n number  seconds to keep tier1 data before compacting to tier2
function Builder:retain_seconds(n)
  self._retain_seconds = n
  return self
end

--- @param fn fun(...number): number  variadic reducer, e.g. math.max or math.min
function Builder:downsample(fn)
  self._downsample = fn
  return self
end

--- @param n number  tier2 window and retain multiplier (default 10)
function Builder:tier2_multiplier(n)
  self._tier2_multiplier = n
  return self
end

--- Construct and return the Tsdb. Validates all required fields.
--- Early assertions here give clearer errors than letting them surface
--- inside RingBuffer.new or ColdStore.new.
--- @param fs    table   injected CC fs handle (or mock)
--- @param path  string  base directory for this metric's tier files
--- @return Tsdb
function Builder:build(fs, path)
  assert(type(self._capacity) == "number" and self._capacity >= 1, "capacity must be a positive integer")
  assert(type(self._window_seconds) == "number" and self._window_seconds > 0, "window_seconds must be a positive number")
  assert(type(self._retain_seconds) == "number" and self._retain_seconds > 0, "retain_seconds must be a positive number")
  assert(type(self._downsample) == "function", "downsample must be a function")
  local ring_buffer = RingBuffer.new(self._capacity)
  local cold_store = ColdStore.new(fs, path, {
    window_seconds = self._window_seconds,
    retain_seconds = self._retain_seconds,
    downsample = self._downsample,
    tier2_multiplier = self._tier2_multiplier,
  })
  return Tsdb.new(ring_buffer, cold_store)
end

return Tsdb
