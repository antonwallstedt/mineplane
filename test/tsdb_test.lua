local Tsdb = require("lib.tsdb")
local fakes = require("test.support.fakes")
local make_fs = fakes.make_fs
local average = fakes.average

local function make_tsdb(overrides)
  local config = overrides or {}
  return Tsdb.builder()
    :capacity(config.capacity or 60)
    :window_seconds(config.window_seconds or 60)
    :retain_seconds(config.retain_seconds or 3600)
    :downsample(config.downsample or average)
    :build(make_fs(), "/data/test")
end

-- ─── builder ──────────────────────────────────────────────────────────────────

describe("Tsdb.builder", function()
  it("rejects missing capacity", function()
    assert.error_matches(function()
      Tsdb.builder()
        :window_seconds(60)
        :retain_seconds(3600)
        :downsample(average)
        :build(make_fs(), "/data/test")
    end, "capacity")
  end)

  it("rejects missing downsample", function()
    assert.error_matches(function()
      Tsdb.builder()
        :capacity(60)
        :window_seconds(60)
        :retain_seconds(3600)
        :build(make_fs(), "/data/test")  -- downsample not set, caught in build()
    end, "downsample")
  end)

  it("builds successfully with all required fields", function()
    local tsdb = make_tsdb()
    assert.truthy(tsdb)
  end)

  it("accepts optional tier2_multiplier", function()
    local tsdb = Tsdb.builder()
      :capacity(60)
      :window_seconds(60)
      :retain_seconds(3600)
      :downsample(average)
      :tier2_multiplier(5)
      :build(make_fs(), "/data/test")
    assert.truthy(tsdb)
  end)
end)

-- ─── push ─────────────────────────────────────────────────────────────────────

describe("Tsdb:push", function()
  it("returns self for chaining", function()
    local tsdb = make_tsdb()
    local result = tsdb:push(1, 10)
    assert.equals(result, tsdb)
  end)

  it("hot samples visible in query before flush", function()
    local tsdb = make_tsdb()
    tsdb:push(100, 42)
    local result = tsdb:query(0, 200)
    assert.equals(#result, 1)
    assert.same(result[1], { time = 100, value = 42 })
  end)
end)

-- ─── flush ────────────────────────────────────────────────────────────────────

describe("Tsdb:flush", function()
  it("clears hot layer after flush", function()
    local tsdb = make_tsdb()
    tsdb:push(100, 10):push(200, 20)
    tsdb:flush(1000)
    local hot_only = tsdb:query(100, 200)
    assert.equals(#hot_only, 1)
  end)

  it("flushed samples remain queryable via cold layer", function()
    local tsdb = make_tsdb({ window_seconds = 60, retain_seconds = 3600 })
    tsdb:push(0, 10):push(30, 20)
    tsdb:flush(500)
    local result = tsdb:query(0, 100)
    assert.equals(#result, 1)
    assert.near(result[1].value, 15, 0.001)
  end)

  it("flush on empty hot layer is a no-op", function()
    local tsdb = make_tsdb()
    tsdb:flush(1000)
    assert.same(tsdb:query(0, 9999), {})
  end)
end)

-- ─── query ────────────────────────────────────────────────────────────────────

describe("Tsdb:query", function()
  it("returns empty when no data", function()
    local tsdb = make_tsdb()
    assert.same(tsdb:query(0, 9999), {})
  end)

  it("merges cold and hot results oldest-first", function()
    local tsdb = make_tsdb({ window_seconds = 60, retain_seconds = 3600 })
    tsdb:push(0, 10):push(30, 20)
    tsdb:flush(500)
    tsdb:push(500, 99)
    local result = tsdb:query(0, 9999)
    assert.equals(#result, 2)
    assert.equals(result[1].time, 0)
    assert.equals(result[2].time, 500)
  end)

  it("respects from/to bounds across layers", function()
    local tsdb = make_tsdb({ window_seconds = 60, retain_seconds = 3600 })
    tsdb:push(0, 1):push(60, 2):push(120, 3)
    tsdb:flush(500)
    tsdb:push(500, 4)
    local result = tsdb:query(60, 500)
    assert.equals(result[1].time, 60)
    assert.equals(result[#result].time, 500)
  end)
end)
