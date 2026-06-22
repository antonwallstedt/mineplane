local ColdStore = require("lib.cold_store")
local fakes = require("test.support.fakes")
local make_fs = fakes.make_fs
local average = fakes.average

local function make_store(overrides)
  local config = overrides or {}
  return ColdStore.new(make_fs(), "/data/test", {
    window_seconds = config.window_seconds or 60,
    retain_seconds = config.retain_seconds or 3600,
    downsample = config.downsample or average,
    tier2_multiplier = config.tier2_multiplier or 10,
  })
end

-- ─── construction ─────────────────────────────────────────────────────────────

describe("ColdStore.new", function()
  it("rejects missing fs", function()
    assert.error_matches(function()
      ColdStore.new(nil, "/data", { window_seconds = 60, retain_seconds = 3600, downsample = average })
    end, "fs must be a table")
  end)

  it("rejects empty base_path", function()
    assert.error_matches(function()
      ColdStore.new(make_fs(), "", { window_seconds = 60, retain_seconds = 3600, downsample = average })
    end, "base_path")
  end)

  it("rejects non-positive window_seconds", function()
    assert.error_matches(function()
      ColdStore.new(make_fs(), "/data", { window_seconds = 0, retain_seconds = 3600, downsample = average })
    end, "window_seconds")
  end)

  it("rejects non-positive retain_seconds", function()
    assert.error_matches(function()
      ColdStore.new(make_fs(), "/data", { window_seconds = 60, retain_seconds = -1, downsample = average })
    end, "retain_seconds")
  end)

  it("rejects missing downsample", function()
    assert.error_matches(function()
      ColdStore.new(make_fs(), "/data", { window_seconds = 60, retain_seconds = 3600 })
    end, "downsample")
  end)
end)

-- ─── flush ────────────────────────────────────────────────────────────────────

describe("ColdStore:flush", function()
  it("does nothing on empty samples", function()
    local fs = make_fs()
    local store = ColdStore.new(fs, "/data/test", { window_seconds = 60, retain_seconds = 3600, downsample = average })
    store:flush({})
    assert.falsy(fs.exists("/data/test/tier1.csv"))
  end)

  it("buckets samples into windows and writes tier1", function()
    local store = make_store()
    store:flush({
      { time = 0,  value = 10 },
      { time = 30, value = 20 },
      { time = 60, value = 30 },
    })
    local result = store:query(0, 120)
    assert.equals(#result, 2)
    assert.same(result[1], { time = 0, value = 15 })
    assert.same(result[2], { time = 60, value = 30 })
  end)

  it("applies downsample per bucket", function()
    local store = make_store({ downsample = math.max })
    store:flush({
      { time = 0,  value = 5  },
      { time = 10, value = 50 },
      { time = 20, value = 3  },
    })
    local result = store:query(0, 59)
    assert.equals(#result, 1)
    assert.same(result[1], { time = 0, value = 50 })
  end)

  it("accumulates across multiple flushes", function()
    local store = make_store()
    store:flush({ { time = 0, value = 10 } })
    store:flush({ { time = 60, value = 20 } })
    local result = store:query(0, 120)
    assert.equals(#result, 2)
  end)
end)

-- ─── query ────────────────────────────────────────────────────────────────────

describe("ColdStore:query", function()
  it("returns empty table when no data", function()
    local store = make_store()
    assert.same(store:query(0, 1000), {})
  end)

  it("filters by time range", function()
    local store = make_store()
    store:flush({
      { time = 0,   value = 1 },
      { time = 60,  value = 2 },
      { time = 120, value = 3 },
    })
    local result = store:query(60, 120)
    assert.equals(#result, 2)
    assert.equals(result[1].time, 60)
    assert.equals(result[2].time, 120)
  end)

  it("returns results oldest-first", function()
    local store = make_store()
    store:flush({
      { time = 120, value = 3 },
      { time = 0,   value = 1 },
      { time = 60,  value = 2 },
    })
    local result = store:query(0, 200)
    assert.equals(result[1].time, 0)
    assert.equals(result[2].time, 60)
    assert.equals(result[3].time, 120)
  end)
end)

-- ─── compact_and_evict ────────────────────────────────────────────────────────

describe("ColdStore:compact_and_evict", function()
  it("does nothing when tier1 is within retain window", function()
    local store = make_store({ window_seconds = 60, retain_seconds = 3600 })
    store:flush({ { time = 1000, value = 5 } })
    store:compact_and_evict(2000)
    local tier1 = store:query(0, 9999)
    assert.equals(#tier1, 1)
  end)

  it("moves old tier1 entries into tier2", function()
    local store = make_store({ window_seconds = 60, retain_seconds = 3600 })
    store:flush({ { time = 0, value = 10 } })
    store:compact_and_evict(5000)
    local result = store:query(0, 9999)
    assert.equals(#result, 1)
    assert.equals(result[1].time, 0)
  end)

  it("tier2 entries use wider window", function()
    local store = make_store({ window_seconds = 60, retain_seconds = 3600, tier2_multiplier = 10 })
    store:flush({
      { time = 0,   value = 10 },
      { time = 60,  value = 20 },
      { time = 120, value = 30 },
    })
    store:compact_and_evict(5000)
    local result = store:query(0, 9999)
    assert.equals(#result, 1)
    assert.equals(result[1].time, 0)
    assert.near(result[1].value, 20, 0.001)
  end)

  it("trims tier2 entries beyond tier2 retain window", function()
    local store = make_store({ window_seconds = 60, retain_seconds = 3600, tier2_multiplier = 2 })
    store:flush({ { time = 0, value = 5 } })
    store:compact_and_evict(100000)
    local result = store:query(0, 9999)
    assert.equals(#result, 0)
  end)
end)
