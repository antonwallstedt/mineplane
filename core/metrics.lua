--- Prometheus-style multi-series registry on top of lib/tsdb.
--- Each unique (name, labels) pair is a distinct series backed by its own Tsdb.
--- Series are discovered lazily: the first record() call for a new (name, labels)
--- pair creates the Tsdb via the injected make_tsdb factory.
---
--- Usage (gateway side):
---   local metrics = Metrics.new(function(name, labels)
---     return Tsdb.builder():capacity(120): ...:build(fs, "/data/" .. name)
---   end)
---   metrics:record("energy.stored", 450000, { segment = "mekanism" }, now)
---   metrics:rate("energy.stored", 10, { segment = "mekanism" })  -- value/sec

local Metrics = {}
Metrics.__index = Metrics

-- ─── internal ─────────────────────────────────────────────────────────────────

--- Canonical series key: label-insertion-order-stable, never exposed to callers.
--- No labels → returns name. With labels → "name{k1=v1,k2=v2}" (keys sorted).
local function series_key(name, labels)
  if not labels or next(labels) == nil then return name end
  local keys = {}
  for k in pairs(labels) do
    table.insert(keys, k)
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, k .. "=" .. tostring(labels[k]))
  end
  return name .. "{" .. table.concat(parts, ",") .. "}"
end

--- Returns the series entry for (name, labels), creating it if absent.
--- Appends to _series_order on first creation to preserve registration order.
function Metrics:_get_or_create(name, labels)
  local key = series_key(name, labels)
  if not self._series[key] then
    self._series[key] = {
      tsdb   = self._make_tsdb(name, labels),
      name   = name,
      labels = labels,
    }
    table.insert(self._series_order, key)
    self._names[name] = true
  end
  return self._series[key]
end

-- ─── constructor ──────────────────────────────────────────────────────────────

--- @param make_tsdb  fun(name: string, labels: table): Tsdb
--- @return Metrics
function Metrics.new(make_tsdb)
  assert(type(make_tsdb) == "function", "make_tsdb must be a function")
  local self = setmetatable({}, Metrics)
  self._make_tsdb     = make_tsdb
  self._series        = {}  -- canonical_key -> { tsdb, name, labels }
  self._series_order  = {}  -- insertion-order list of canonical keys
  self._names         = {}  -- name -> true  (unique name set)
  return self
end

-- ─── mutating ─────────────────────────────────────────────────────────────────

--- Record a sample. Creates the series on first call.
--- @param name    string
--- @param value   number
--- @param labels  table|nil  defaults to {}
--- @param t       number     epoch seconds
--- @return Metrics  self, for chaining
function Metrics:record(name, value, labels, t)
  assert(type(name) == "string" and name ~= "", "name must be a non-empty string")
  assert(type(value) == "number", "value must be a number")
  assert(type(t) == "number", "t must be a number (epoch seconds)")
  labels = labels or {}
  local entry = self:_get_or_create(name, labels)
  entry.tsdb:push(t, value)
  return self
end

-- ─── query helpers ────────────────────────────────────────────────────────────

--- Returns last n samples for (name, labels), oldest-first.
--- Queries the full hot+cold Tsdb range and takes the tail.
--- Returns {} when series does not exist or has no samples.
--- @param name    string
--- @param n       integer
--- @param labels  table|nil
--- @return {time:number, value:number}[]
function Metrics:range(name, n, labels)
  labels = labels or {}
  local entry = self._series[series_key(name, labels)]
  if not entry then return {} end
  local all = entry.tsdb:query(0, math.huge)
  local count = #all
  if count == 0 then return {} end
  n = math.min(n, count)
  local result = {}
  for i = count - n + 1, count do
    table.insert(result, all[i])
  end
  return result
end

-- ─── public query API ─────────────────────────────────────────────────────────

--- Most recent sample, or nil if the series is empty or does not exist.
--- @param name    string
--- @param labels  table|nil
--- @return {time:number, value:number}|nil
function Metrics:latest(name, labels)
  local samples = self:range(name, 1, labels)
  return samples[1]
end

--- Average value over the last n samples, or nil if no data.
--- @param name    string
--- @param n       integer
--- @param labels  table|nil
--- @return number|nil
function Metrics:avg(name, n, labels)
  local samples = self:range(name, n, labels)
  if #samples == 0 then return nil end
  local sum = 0
  for _, s in ipairs(samples) do
    sum = sum + s.value
  end
  return sum / #samples
end

--- Maximum value over the last n samples, or nil if no data.
--- @param name    string
--- @param n       integer
--- @param labels  table|nil
--- @return number|nil
function Metrics:max(name, n, labels)
  local samples = self:range(name, n, labels)
  if #samples == 0 then return nil end
  local m = samples[1].value
  for i = 2, #samples do
    if samples[i].value > m then m = samples[i].value end
  end
  return m
end

--- Minimum value over the last n samples, or nil if no data.
--- @param name    string
--- @param n       integer
--- @param labels  table|nil
--- @return number|nil
function Metrics:min(name, n, labels)
  local samples = self:range(name, n, labels)
  if #samples == 0 then return nil end
  local m = samples[1].value
  for i = 2, #samples do
    if samples[i].value < m then m = samples[i].value end
  end
  return m
end

--- Per-second rate of change over the last n samples via OLS linear regression.
--- Returns nil when fewer than 2 samples are available (slope undefined).
--- Returns 0 when all timestamps are identical (cannot distinguish from flat).
--- Timestamps are normalized to t0 = oldest sample time before squaring to
--- avoid float precision loss with large epoch values (~1.7e9 squared).
--- @param name    string
--- @param n       integer
--- @param labels  table|nil
--- @return number|nil
function Metrics:rate(name, n, labels)
  local samples = self:range(name, n, labels)
  if #samples < 2 then return nil end
  local N = #samples
  local t0 = samples[1].time
  local sum_t, sum_v, sum_tt, sum_tv = 0, 0, 0, 0
  for _, s in ipairs(samples) do
    local t = s.time - t0
    sum_t  = sum_t  + t
    sum_v  = sum_v  + s.value
    sum_tt = sum_tt + t * t
    sum_tv = sum_tv + t * s.value
  end
  local denom = N * sum_tt - sum_t * sum_t
  if denom == 0 then return 0 end
  return (N * sum_tv - sum_t * sum_v) / denom
end

--- Sum of latest() values across all series matching name and a label subset.
--- label_subset = {} matches every series registered under name.
--- Returns nil when no data is found: name unknown, label subset matched nothing,
--- or all matching series have no samples yet.
--- Iterates in registration order for deterministic results.
--- @param name          string
--- @param label_subset  table|nil
--- @return number|nil
function Metrics:sum_latest(name, label_subset)
  label_subset = label_subset or {}
  local total = 0
  local found = false
  for _, key in ipairs(self._series_order) do
    local entry = self._series[key]
    if entry.name == name then
      local match = true
      for k, v in pairs(label_subset) do
        if entry.labels[k] ~= v then
          match = false
          break
        end
      end
      if match then
        local sample = self:latest(name, entry.labels)
        if sample then
          total = total + sample.value
          found = true
        end
      end
    end
  end
  if not found then return nil end
  return total
end

-- ─── introspection ────────────────────────────────────────────────────────────

--- All unique metric names, sorted alphabetically.
--- @return string[]
function Metrics:metric_names()
  local names = {}
  for name in pairs(self._names) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Label tables for every series registered under name, in registration order.
--- @param name  string
--- @return table[]
function Metrics:series_labels(name)
  local result = {}
  for _, key in ipairs(self._series_order) do
    local entry = self._series[key]
    if entry.name == name then
      table.insert(result, entry.labels)
    end
  end
  return result
end

return Metrics
