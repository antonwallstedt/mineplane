--- Disk-backed cold storage for a single metric.
--- Manages two tier files (tier1.csv, tier2.csv) under a base path.
--- All fs access is injected — no CC globals at module load time.
---
--- Tier layout:
---   tier1: recent samples at window_seconds resolution
---   tier2: older samples at (window_seconds * tier2_multiplier) resolution
---
--- CSV format: one "time,value" pair per line, oldest first.

local ColdStore = {}
ColdStore.__index = ColdStore

local DEFAULT_TIER2_MULTIPLIER = 10

--- @param fs table             injected CC fs handle (or mock)
--- @param base_path string     directory for this metric's tier files
--- @param config table         { window_seconds, retain_seconds, downsample, tier2_multiplier? }
--- @return ColdStore
function ColdStore.new(fs, base_path, config)
  assert(type(fs) == "table", "fs must be a table")
  assert(type(base_path) == "string" and base_path ~= "", "base_path must be a non-empty string")
  assert(
    type(config.window_seconds) == "number" and config.window_seconds > 0,
    "window_seconds must be a positive number"
  )
  assert(
    type(config.retain_seconds) == "number" and config.retain_seconds > 0,
    "retain_seconds must be a positive number"
  )
  assert(type(config.downsample) == "function", "downsample must be a function")
  local multiplier = config.tier2_multiplier or DEFAULT_TIER2_MULTIPLIER
  local self = setmetatable({}, ColdStore)
  self._fs = fs
  self._base_path = base_path
  self._window_seconds = config.window_seconds
  self._retain_seconds = config.retain_seconds
  self._tier2_window_seconds = config.window_seconds * multiplier
  self._tier2_retain_seconds = config.retain_seconds * multiplier
  self._downsample = config.downsample
  return self
end

-- ─── internal I/O ─────────────────────────────────────────────────────────────

local function parse_csv_line(line)
  local t, v = line:match("^([^,]+),([^,]+)$")
  if t and v then
    return { time = tonumber(t), value = tonumber(v) }
  end
end

function ColdStore:_tier_path(tier)
  return self._base_path .. "/" .. tier .. ".csv"
end

function ColdStore:_read_tier(tier)
  local path = self:_tier_path(tier)
  if not self._fs.exists(path) then
    return {}
  end
  local file = self._fs.open(path, "r")
  local samples = {}
  local line = file:readLine()
  while line do
    local sample = parse_csv_line(line)
    if sample then
      table.insert(samples, sample)
    end
    line = file:readLine()
  end
  file:close()
  return samples
end

function ColdStore:_append_tier(tier, samples)
  if #samples == 0 then
    return
  end
  local file = self._fs.open(self:_tier_path(tier), "a")
  for _, s in ipairs(samples) do
    file:writeLine(s.time .. "," .. s.value)
  end
  file:close()
end

-- Passing empty samples intentionally truncates the file — used by
-- compact_and_evict to reset a tier after all entries have been promoted.
function ColdStore:_write_tier(tier, samples)
  local file = self._fs.open(self:_tier_path(tier), "w")
  for _, s in ipairs(samples) do
    file:writeLine(s.time .. "," .. s.value)
  end
  file:close()
end

-- ─── bucketing ────────────────────────────────────────────────────────────────

-- Pure function — no dependency on self or any tier state.
-- Groups samples into fixed-width time windows and reduces each window to one
-- sample using downsample. Returns results oldest-first.
--
-- Each output sample's time is the start of its bucket (floor of the window).
-- Samples with no bucket peers are still passed through downsample as a
-- single-element call.
local function bucket(samples, window, downsample)
  local buckets = {}
  for _, s in ipairs(samples) do
    local key = math.floor(s.time / window) * window
    if not buckets[key] then
      buckets[key] = {}
    end
    table.insert(buckets[key], s.value)
  end
  local keys = {}
  for key in pairs(buckets) do
    table.insert(keys, key)
  end
  table.sort(keys)
  local result = {}
  for _, key in ipairs(keys) do
    table.insert(result, { time = key, value = downsample(table.unpack(buckets[key])) })
  end
  return result
end

-- ─── public API ───────────────────────────────────────────────────────────────

--- Flush raw samples (from ring buffer) into tier1.
--- @param samples  {time:number, value:number}[]
function ColdStore:flush(samples)
  if #samples == 0 then
    return
  end
  self:_append_tier("tier1", bucket(samples, self._window_seconds, self._downsample))
end

--- Move tier1 entries older than retain_seconds into tier2, then trim tier2.
--- @param now_seconds  number  current epoch seconds (injected for testability)
function ColdStore:compact_and_evict(now_seconds)
  local tier1 = self:_read_tier("tier1")
  local cutoff = now_seconds - self._retain_seconds
  local old, recent = {}, {}
  for _, s in ipairs(tier1) do
    if s.time < cutoff then
      table.insert(old, s)
    else
      table.insert(recent, s)
    end
  end
  if #old > 0 then
    self:_append_tier("tier2", bucket(old, self._tier2_window_seconds, self._downsample))
    self:_write_tier("tier1", recent)
  end

  local tier2_cutoff = now_seconds - self._tier2_retain_seconds
  local tier2 = self:_read_tier("tier2")
  local live_tier2 = {}
  for _, s in ipairs(tier2) do
    if s.time >= tier2_cutoff then
      table.insert(live_tier2, s)
    end
  end
  if #live_tier2 ~= #tier2 then
    self:_write_tier("tier2", live_tier2)
  end
end

--- Query samples in [from, to] across both tiers, oldest-first.
--- @param from  number  epoch seconds
--- @param to    number  epoch seconds
--- @return {time:number, value:number}[]
function ColdStore:query(from, to)
  local result = {}
  for _, s in ipairs(self:_read_tier("tier2")) do
    if s.time >= from and s.time <= to then
      table.insert(result, s)
    end
  end
  for _, s in ipairs(self:_read_tier("tier1")) do
    if s.time >= from and s.time <= to then
      table.insert(result, s)
    end
  end
  return result
end

return ColdStore
