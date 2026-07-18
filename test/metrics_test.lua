local Metrics = require("core.metrics")
local Tsdb    = require("lib.tsdb")
local fakes   = require("test.support.fakes")

-- ─── test factory ─────────────────────────────────────────────────────────────

local function make_factory(fs)
  fs = fs or fakes.make_fs()
  return function(name, _labels)
    return Tsdb.builder()
      :capacity(20)
      :window_seconds(60)
      :retain_seconds(3600)
      :downsample(fakes.average)
      :build(fs, "/metrics/" .. name)
  end
end

local function make_metrics(fs)
  return Metrics.new(make_factory(fs))
end

-- ─── Metrics.new ──────────────────────────────────────────────────────────────

describe("Metrics.new", function()
  it("rejects a non-function make_tsdb", function()
    assert.error_matches(function() Metrics.new("bad") end, "make_tsdb must be a function")
  end)

  it("rejects nil make_tsdb", function()
    assert.error_matches(function() Metrics.new(nil) end, "make_tsdb must be a function")
  end)

  it("constructs successfully with a valid factory", function()
    local m = make_metrics()
    assert.truthy(m)
  end)
end)

-- ─── record ───────────────────────────────────────────────────────────────────

describe("record", function()
  it("rejects empty name", function()
    local m = make_metrics()
    assert.error_matches(function() m:record("", 1, {}, 100) end, "name must be a non%-empty string")
  end)

  it("rejects non-number value", function()
    local m = make_metrics()
    assert.error_matches(function() m:record("cpu", "high", {}, 100) end, "value must be a number")
  end)

  it("rejects non-number timestamp", function()
    local m = make_metrics()
    assert.error_matches(function() m:record("cpu", 1, {}, "now") end, "t must be a number")
  end)

  it("accepts nil labels (treated as empty)", function()
    local m = make_metrics()
    m:record("cpu", 0.5, nil, 100)
    assert.truthy(m:latest("cpu", {}))
  end)

  it("creates a new series on first record", function()
    local m = make_metrics()
    m:record("energy.stored", 450000, { segment = "mek" }, 100)
    assert.same(m:metric_names(), { "energy.stored" })
  end)

  it("two records with same name+labels land in the same series", function()
    local m = make_metrics()
    m:record("fuel", 100, {}, 1)
    m:record("fuel", 200, {}, 2)
    assert.equals(#m:range("fuel", 10, {}), 2)
  end)

  it("label insertion order does not affect series identity", function()
    local m = make_metrics()
    m:record("flow", 1, { node = "a", segment = "mek" }, 1)
    m:record("flow", 2, { segment = "mek", node = "a" }, 2)
    assert.equals(#m:range("flow", 10, { node = "a", segment = "mek" }), 2)
  end)

  it("different label values produce distinct series", function()
    local m = make_metrics()
    m:record("flow", 10, { segment = "mek" }, 1)
    m:record("flow", 20, { segment = "rf" }, 1)
    assert.equals(#m:series_labels("flow"), 2)
  end)

  it("returns self for chaining", function()
    local m = make_metrics()
    assert.equals(m:record("x", 1, {}, 1), m)
  end)
end)

-- ─── latest / range ───────────────────────────────────────────────────────────

describe("latest", function()
  it("returns nil for unknown series", function()
    local m = make_metrics()
    assert.is_nil(m:latest("missing", {}))
  end)

  it("returns the single pushed sample", function()
    local m = make_metrics()
    m:record("v", 42, {}, 100)
    local s = m:latest("v", {})
    assert.equals(s.value, 42)
    assert.equals(s.time, 100)
  end)

  it("returns the most recent sample after multiple pushes", function()
    local m = make_metrics()
    m:record("v", 1, {}, 1)
    m:record("v", 9, {}, 2)
    m:record("v", 5, {}, 3)
    assert.equals(m:latest("v", {}).value, 5)
  end)
end)

describe("range", function()
  it("returns empty table for unknown series", function()
    local m = make_metrics()
    assert.same(m:range("missing", 5, {}), {})
  end)

  it("returns samples oldest-first", function()
    local m = make_metrics()
    m:record("v", 10, {}, 1)
    m:record("v", 20, {}, 2)
    m:record("v", 30, {}, 3)
    local r = m:range("v", 3, {})
    assert.equals(r[1].value, 10)
    assert.equals(r[3].value, 30)
  end)

  it("clamps silently when n > count", function()
    local m = make_metrics()
    m:record("v", 1, {}, 1)
    assert.equals(#m:range("v", 100, {}), 1)
  end)

  it("returns last n when more samples exist", function()
    local m = make_metrics()
    for i = 1, 5 do m:record("v", i, {}, i) end
    local r = m:range("v", 3, {})
    assert.equals(#r, 3)
    assert.equals(r[1].value, 3)
    assert.equals(r[3].value, 5)
  end)
end)

-- ─── avg / max / min ──────────────────────────────────────────────────────────

describe("avg", function()
  it("returns nil for unknown series", function()
    assert.is_nil(make_metrics():avg("x", 5, {}))
  end)

  it("returns value for single sample", function()
    local m = make_metrics()
    m:record("x", 7, {}, 1)
    assert.equals(m:avg("x", 5, {}), 7)
  end)

  it("averages last n samples", function()
    local m = make_metrics()
    for i = 1, 4 do m:record("x", i * 10, {}, i) end
    -- last 3: 20, 30, 40 → avg 30
    assert.near(m:avg("x", 3, {}), 30, 1e-9)
  end)
end)

describe("max", function()
  it("returns nil for unknown series", function()
    assert.is_nil(make_metrics():max("x", 5, {}))
  end)

  it("returns max over last n", function()
    local m = make_metrics()
    m:record("x", 5, {}, 1)
    m:record("x", 1, {}, 2)
    m:record("x", 9, {}, 3)
    m:record("x", 3, {}, 4)
    -- last 3: 1, 9, 3
    assert.equals(m:max("x", 3, {}), 9)
  end)
end)

describe("min", function()
  it("returns nil for unknown series", function()
    assert.is_nil(make_metrics():min("x", 5, {}))
  end)

  it("returns min over last n", function()
    local m = make_metrics()
    m:record("x", 5, {}, 1)
    m:record("x", 1, {}, 2)
    m:record("x", 9, {}, 3)
    m:record("x", 3, {}, 4)
    -- last 3: 1, 9, 3
    assert.equals(m:min("x", 3, {}), 1)
  end)
end)

-- ─── rate ─────────────────────────────────────────────────────────────────────

describe("rate", function()
  it("returns nil for unknown series", function()
    assert.is_nil(make_metrics():rate("x", 5, {}))
  end)

  it("returns nil with only one sample", function()
    local m = make_metrics()
    m:record("x", 10, {}, 1)
    assert.is_nil(m:rate("x", 5, {}))
  end)

  it("returns 0 for a flat line", function()
    local m = make_metrics()
    m:record("x", 5, {}, 1)
    m:record("x", 5, {}, 2)
    m:record("x", 5, {}, 3)
    assert.equals(m:rate("x", 3, {}), 0)
  end)

  it("returns 0 when all timestamps are identical", function()
    local m = make_metrics()
    m:record("x", 10, {}, 100)
    m:record("x", 20, {}, 100)
    assert.equals(m:rate("x", 2, {}), 0)
  end)

  it("returns exact slope for a perfectly linear series", function()
    -- v = 2t → slope = 2 value/sec
    local m = make_metrics()
    m:record("x", 0, {}, 0)
    m:record("x", 2, {}, 1)
    m:record("x", 4, {}, 2)
    assert.near(m:rate("x", 3, {}), 2, 1e-9)
  end)

  it("returns negative slope for a declining series", function()
    local m = make_metrics()
    m:record("x", 100, {}, 0)
    m:record("x", 50,  {}, 1)
    m:record("x", 0,   {}, 2)
    assert.near(m:rate("x", 3, {}), -50, 1e-9)
  end)

  it("returns OLS slope for noisy data (regression, not just endpoints)", function()
    -- points: (0,0),(1,3),(2,2),(3,5)
    local m = make_metrics()
    m:record("x", 0, {}, 0)
    m:record("x", 3, {}, 1)
    m:record("x", 2, {}, 2)
    m:record("x", 5, {}, 3)
    -- OLS: N=4, Σt=6, Σv=10, Σt²=14, Σtv=22
    -- denom = 4*14 - 6²  = 56-36 = 20
    -- slope = (4*22 - 6*10)/20 = (88-60)/20 = 1.4
    assert.near(m:rate("x", 4, {}), 1.4, 1e-9)
  end)

  it("clamps n to available samples", function()
    local m = make_metrics()
    m:record("x", 0, {}, 0)
    m:record("x", 4, {}, 2)
    -- only 2 samples available; slope = 2 value/sec
    assert.near(m:rate("x", 100, {}), 2, 1e-9)
  end)

  it("operates correctly on large epoch timestamps", function()
    local base = 1700000000  -- realistic CC epoch (~2023)
    local m = make_metrics()
    m:record("x", 0, {}, base)
    m:record("x", 2, {}, base + 1)
    m:record("x", 4, {}, base + 2)
    assert.near(m:rate("x", 3, {}), 2, 1e-6)
  end)
end)

-- ─── sum_latest ───────────────────────────────────────────────────────────────

describe("sum_latest", function()
  it("returns nil when no series with that name exist", function()
    assert.is_nil(make_metrics():sum_latest("missing", {}))
  end)

  it("returns nil when series exist but label subset matches nothing", function()
    local m = make_metrics()
    m:record("e", 100, { seg = "a" }, 1)
    assert.is_nil(m:sum_latest("e", { seg = "z" }))
  end)

  it("sums latest across all series when label_subset is empty", function()
    local m = make_metrics()
    m:record("e", 100, { seg = "a" }, 1)
    m:record("e", 200, { seg = "b" }, 1)
    assert.equals(m:sum_latest("e", {}), 300)
  end)

  it("filters by partial label subset", function()
    local m = make_metrics()
    m:record("e", 100, { seg = "a", node = "1" }, 1)
    m:record("e", 200, { seg = "b", node = "1" }, 1)
    m:record("e", 400, { seg = "a", node = "2" }, 1)
    -- only seg="a" → 100 + 400
    assert.equals(m:sum_latest("e", { seg = "a" }), 500)
  end)

  it("uses latest sample per series (not all samples)", function()
    local m = make_metrics()
    m:record("e", 50,  { seg = "a" }, 1)
    m:record("e", 100, { seg = "a" }, 2)  -- latest
    assert.equals(m:sum_latest("e", {}), 100)
  end)
end)

-- ─── metric_names / series_labels ─────────────────────────────────────────────

describe("metric_names", function()
  it("returns empty list when no metrics recorded", function()
    assert.same(make_metrics():metric_names(), {})
  end)

  it("returns unique names sorted alphabetically", function()
    local m = make_metrics()
    m:record("fuel.level",    1, {}, 1)
    m:record("energy.stored", 2, {}, 1)
    m:record("fuel.level",    3, {}, 2)  -- duplicate name, same series
    assert.same(m:metric_names(), { "energy.stored", "fuel.level" })
  end)
end)

describe("series_labels", function()
  it("returns empty list for unknown metric", function()
    assert.same(make_metrics():series_labels("missing"), {})
  end)

  it("returns one entry per distinct label set", function()
    local m = make_metrics()
    m:record("flow", 1, { seg = "a" }, 1)
    m:record("flow", 2, { seg = "b" }, 1)
    assert.equals(#m:series_labels("flow"), 2)
  end)

  it("does not duplicate when same series recorded twice", function()
    local m = make_metrics()
    m:record("flow", 1, { seg = "a" }, 1)
    m:record("flow", 2, { seg = "a" }, 2)
    assert.equals(#m:series_labels("flow"), 1)
  end)

  it("returns labels in registration order", function()
    local m = make_metrics()
    m:record("flow", 1, { seg = "a" }, 1)
    m:record("flow", 2, { seg = "b" }, 1)
    m:record("flow", 3, { seg = "c" }, 1)
    local labels = m:series_labels("flow")
    assert.equals(labels[1].seg, "a")
    assert.equals(labels[2].seg, "b")
    assert.equals(labels[3].seg, "c")
  end)

  it("interleaved names do not disrupt per-name ordering", function()
    local m = make_metrics()
    m:record("flow",  1, { seg = "x" }, 1)
    m:record("power", 1, { seg = "y" }, 1)
    m:record("flow",  2, { seg = "z" }, 1)
    local flow_labels = m:series_labels("flow")
    assert.equals(flow_labels[1].seg, "x")
    assert.equals(flow_labels[2].seg, "z")
  end)
end)
