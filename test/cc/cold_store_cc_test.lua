-- Integration tests for ColdStore using the REAL CC fs API.
-- Only runs under CraftOS-PC (test/cc_runner.lua / scripts/test-cc.sh).
-- The vanilla runner excludes test/cc/ via -maxdepth 1.

local ColdStore = require("lib.cold_store")
local fakes     = require("test.support.fakes")

local TEST_DIR = "/cc_cold_store_test"

-- window=10s so two samples 5s apart land in the same bucket.
-- retain=60s so a bucket at t=100 is evicted when now=200 (cutoff=140).
local function make_store()
  if fs.exists(TEST_DIR) then fs.delete(TEST_DIR) end
  return ColdStore.new(fs, TEST_DIR, {
    window_seconds = 10,
    retain_seconds = 60,
    downsample     = fakes.average,
  })
end

describe("ColdStore (real CC fs)", function()
  it("flush creates tier1.csv on disk", function()
    local store = make_store()
    store:flush({ { time = 100, value = 1 } })
    assert.truthy(fs.exists(TEST_DIR .. "/tier1.csv"))
  end)

  it("query reads a flushed sample back correctly", function()
    local store = make_store()
    -- Two samples in the same 10s window — averaged on flush.
    store:flush({ { time = 100, value = 4 }, { time = 105, value = 6 } })
    local results = store:query(0, 200)
    assert.equals(#results, 1)
    assert.equals(results[1].time, 100)
    assert.near(results[1].value, 5, 0.001)
  end)

  it("data persists when a new ColdStore opens the same path", function()
    local store1 = make_store()
    store1:flush({ { time = 100, value = 42 } })
    -- Open a second instance at the same base path — no flush involved.
    local store2 = ColdStore.new(fs, TEST_DIR, {
      window_seconds = 10,
      retain_seconds = 60,
      downsample     = fakes.average,
    })
    local results = store2:query(0, 200)
    assert.equals(#results, 1)
    assert.near(results[1].value, 42, 0.001)
  end)

  it("multiple flushes append — both entries visible before compaction", function()
    local store = make_store()
    store:flush({ { time = 100, value = 2 } })
    store:flush({ { time = 105, value = 8 } })
    -- Each flush buckets independently and appends; tier1 has two lines
    -- both at bucket-time 100 but with their individual downsampled values.
    local results = store:query(0, 200)
    assert.equals(#results, 2)
  end)

  it("compact_and_evict creates tier2.csv", function()
    local store = make_store()
    store:flush({ { time = 100, value = 3 } })
    -- now=200, retain=60 → cutoff=140; bucket at 100 < 140, so evicted.
    store:compact_and_evict(200)
    assert.truthy(fs.exists(TEST_DIR .. "/tier2.csv"))
  end)

  it("evicted samples are queryable from tier2", function()
    local store = make_store()
    store:flush({ { time = 100, value = 3 } })
    store:compact_and_evict(200)
    -- tier2 window = 10*10 = 100; bucket for t=100 is floor(100/100)*100 = 100.
    local results = store:query(0, 200)
    assert.equals(#results, 1)
    assert.near(results[1].value, 3, 0.001)
  end)

  it("tier1 is cleared after compaction — no duplicates in full query", function()
    local store = make_store()
    store:flush({ { time = 100, value = 7 } })
    store:compact_and_evict(200)
    -- tier2_window = 10*10 = 100; bucket for t=100 is floor(100/100)*100 = 100.
    -- Promoted sample is now in tier2 at t=100. tier1 should be empty.
    -- If tier1 were NOT cleared, query would return 2 results (tier2 + tier1 duplicate).
    local store2 = ColdStore.new(fs, TEST_DIR, {
      window_seconds = 10,
      retain_seconds = 60,
      downsample     = fakes.average,
    })
    local results = store2:query(0, 300)
    assert.equals(#results, 1)
  end)

  it("recent tier1 entries survive compaction", function()
    local store = make_store()
    store:flush({ { time = 100, value = 1 } })  -- old, will be evicted
    store:flush({ { time = 180, value = 9 } })  -- recent: 180 > cutoff 140, stays
    store:compact_and_evict(200)
    local results = store:query(170, 200)
    assert.equals(#results, 1)
    assert.near(results[1].value, 9, 0.001)
  end)

  -- Final cleanup.
  if fs.exists(TEST_DIR) then fs.delete(TEST_DIR) end
end)
