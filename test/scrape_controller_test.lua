local ScrapeController = require("core.scrape_controller")
local FlushController  = require("core.flush_controller")
local fakes            = require("test.support.fakes")

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function make_ctx(epoch_ms)
  local sleeps = {}
  return {
    os = {
      sleep = function(n) table.insert(sleeps, n) end,
      epoch = function(_) return epoch_ms or 5000000 end,
    },
    sleeps = sleeps,
  }
end

local function make_scraper(overrides)
  local config = overrides or {}
  return ScrapeController.new(
    config.ctx or make_ctx(),
    config.interval_seconds or 15,
    {
      fs        = config.fs or fakes.make_fs(),
      base_path = config.base_path or "/data/metrics",
      defaults  = config.defaults,
    }
  )
end

local function make_collector(name, fn)
  return { name = name, collect = fn or function() return 1 end }
end

local function make_failing_collector(name)
  return { name = name, collect = function() error("sensor offline") end }
end

local function make_nil_collector(name)
  return { name = name, collect = function() return nil end }
end

-- ─── construction ─────────────────────────────────────────────────────────────

describe("ScrapeController.new", function()
  it("rejects missing ctx.os", function()
    assert.error_matches(function()
      ScrapeController.new({}, 15, { fs = fakes.make_fs(), base_path = "/data" })
    end, "ctx.os is required")
  end)

  it("rejects non-positive interval", function()
    assert.error_matches(function()
      ScrapeController.new(make_ctx(), 0, { fs = fakes.make_fs(), base_path = "/data" })
    end, "interval_seconds")
  end)

  it("rejects missing opts", function()
    assert.error_matches(function()
      ScrapeController.new(make_ctx(), 15, nil)
    end, "opts is required")
  end)

  it("rejects missing opts.fs", function()
    assert.error_matches(function()
      ScrapeController.new(make_ctx(), 15, { base_path = "/data" })
    end, "opts.fs is required")
  end)

  it("rejects missing opts.base_path", function()
    assert.error_matches(function()
      ScrapeController.new(make_ctx(), 15, { fs = fakes.make_fs() })
    end, "opts.base_path")
  end)

  it("constructs with valid args", function()
    assert.truthy(make_scraper())
  end)
end)

-- ─── register ─────────────────────────────────────────────────────────────────

describe("ScrapeController:register", function()
  it("rejects empty name", function()
    assert.error_matches(function()
      make_scraper():register({ name = "", collect = function() end })
    end, "non%-empty string")
  end)

  it("rejects slash in name", function()
    assert.error_matches(function()
      make_scraper():register({ name = "a/b", collect = function() end })
    end, "slashes")
  end)

  it("rejects whitespace in name", function()
    assert.error_matches(function()
      make_scraper():register({ name = "a b", collect = function() end })
    end, "whitespace")
  end)

  it("rejects missing collect", function()
    assert.error_matches(function()
      make_scraper():register({ name = "fuel" })
    end, "collect must be a function")
  end)

  it("returns self for chaining", function()
    local sc = make_scraper()
    assert.equals(sc:register(make_collector("fuel")), sc)
  end)

  it("accepts minimal collector", function()
    make_scraper():register(make_collector("fuel"))
  end)

  it("accepts collector with all optional storage fields", function()
    make_scraper():register({
      name           = "entities",
      collect        = function() return 5 end,
      downsample     = math.max,
      window_seconds = 30,
      retain_seconds = 7200,
      capacity       = 60,
    })
  end)
end)

-- ─── step ─────────────────────────────────────────────────────────────────────

describe("ScrapeController:step", function()
  it("sleeps for the configured interval after scraping", function()
    local ctx = make_ctx()
    local sc = make_scraper({ ctx = ctx, interval_seconds = 30 })
    sc:register(make_collector("fuel"))
    sc:step()
    assert.equals(ctx.sleeps[1], 30)
  end)

  it("returns epoch seconds (not ms)", function()
    local ctx = make_ctx(8000000)
    local sc = make_scraper({ ctx = ctx })
    local now = sc:step()
    assert.near(now, 8000, 0.001)
  end)

  it("pushes number result into tsdb", function()
    local sc = make_scraper({ ctx = make_ctx(5000000) })
    sc:register(make_collector("fuel", function() return 42 end))
    local now = sc:step()
    local results = sc:tsdbs()[1]:query(now - 1, now + 1)
    assert.equals(#results, 1)
    assert.near(results[1].value, 42, 0.001)
  end)

  it("skips nil result with no push and no error", function()
    local sc = make_scraper({ ctx = make_ctx(5000000) })
    sc:register(make_nil_collector("fuel"))
    local now = sc:step()
    assert.same(sc:tsdbs()[1]:query(0, now + 1), {})
    assert.same(sc:errors(), {})
  end)

  it("passes ctx to collect", function()
    local received_ctx
    local ctx = make_ctx()
    local sc = make_scraper({ ctx = ctx })
    sc:register(make_collector("x", function(c) received_ctx = c; return 1 end))
    sc:step()
    assert.equals(received_ctx, ctx)
  end)

  it("passes now to collect", function()
    local received_now
    local ctx = make_ctx(9000000)
    local sc = make_scraper({ ctx = ctx })
    sc:register(make_collector("x", function(_, n) received_now = n; return 1 end))
    local now = sc:step()
    assert.near(received_now, now, 0.001)
  end)

  it("all collectors in one step share the same timestamp", function()
    local timestamps = {}
    local ctx = make_ctx(6000000)
    local sc = make_scraper({ ctx = ctx })
    sc:register(make_collector("a", function(_, n) table.insert(timestamps, n); return 1 end))
    sc:register(make_collector("b", function(_, n) table.insert(timestamps, n); return 1 end))
    sc:step()
    assert.equals(#timestamps, 2)
    assert.equals(timestamps[1], timestamps[2])
  end)

  it("with no collectors is a no-op beyond sleeping", function()
    local ctx = make_ctx()
    local sc = make_scraper({ ctx = ctx })
    sc:step()
    assert.equals(#ctx.sleeps, 1)
    assert.same(sc:errors(), {})
  end)
end)

-- ─── error isolation ──────────────────────────────────────────────────────────

describe("ScrapeController error isolation", function()
  it("one failing collector does not prevent others from being scraped", function()
    local ctx = make_ctx(5000000)
    local sc = make_scraper({ ctx = ctx })
    sc:register(make_failing_collector("bad"))
    sc:register(make_collector("good", function() return 99 end))
    local now = sc:step()
    local good_results = sc:tsdbs()[2]:query(now - 1, now + 1)
    assert.equals(#good_results, 1)
    assert.near(good_results[1].value, 99, 0.001)
  end)

  it("records error count and message for failing collector", function()
    local sc = make_scraper()
    sc:register(make_failing_collector("broken"))
    sc:step()
    local errs = sc:errors()
    assert.equals(errs["broken"].count, 1)
    assert.truthy(errs["broken"].last_message:match("sensor offline"))
  end)

  it("error count grows monotonically across multiple failures", function()
    local sc = make_scraper()
    sc:register(make_failing_collector("broken"))
    sc:step()
    sc:step()
    sc:step()
    assert.equals(sc:errors()["broken"].count, 3)
  end)

  it("successful scrape after failure still pushes and does not reset error count", function()
    local call_count = 0
    local ctx = make_ctx(5000000)
    local sc = make_scraper({ ctx = ctx })
    sc:register(make_collector("flaky", function()
      call_count = call_count + 1
      if call_count == 1 then error("temporary failure") end
      return 7
    end))
    sc:step()
    local now = sc:step()
    local results = sc:tsdbs()[1]:query(now - 1, now + 1)
    assert.equals(#results, 1)
    assert.near(results[1].value, 7, 0.001)
    assert.equals(sc:errors()["flaky"].count, 1)
  end)
end)

-- ─── tsdbs ────────────────────────────────────────────────────────────────────

describe("ScrapeController:tsdbs", function()
  it("returns empty table when no collectors registered", function()
    assert.same(make_scraper():tsdbs(), {})
  end)

  it("returns one TSDB per registered collector", function()
    local sc = make_scraper()
    sc:register(make_collector("a")):register(make_collector("b")):register(make_collector("c"))
    assert.equals(#sc:tsdbs(), 3)
  end)

  it("returns TSDBs in registration order", function()
    local ctx = make_ctx(5000000)
    local sc = make_scraper({ ctx = ctx })
    sc:register(make_collector("first",  function() return 1 end))
    sc:register(make_collector("second", function() return 2 end))
    local now = sc:step()
    assert.near(sc:tsdbs()[1]:query(now - 1, now + 1)[1].value, 1, 0.001)
    assert.near(sc:tsdbs()[2]:query(now - 1, now + 1)[1].value, 2, 0.001)
  end)
end)

-- ─── integration with FlushController ────────────────────────────────────────

describe("ScrapeController + FlushController integration", function()
  it("flushed samples from both collectors remain queryable", function()
    local epoch_ms = 5000000
    local ctx = {
      os = {
        sleep = function() end,
        epoch = function(_) return epoch_ms end,
      },
    }
    local sc = ScrapeController.new(ctx, 15, { fs = fakes.make_fs(), base_path = "/data" })
    local fc = FlushController.new(ctx, 60)

    sc:register(make_collector("alpha", function() return 10 end))
    sc:register(make_collector("beta",  function() return 20 end))

    for _, tsdb in ipairs(sc:tsdbs()) do
      fc:register(tsdb)
    end

    sc:step()
    fc:step()

    local now = epoch_ms / 1000
    -- after flush, samples are bucketed; bucket time may be up to window_seconds (60s) behind now
    local alpha = sc:tsdbs()[1]:query(now - 120, now + 1)
    local beta  = sc:tsdbs()[2]:query(now - 120, now + 1)
    assert.equals(#alpha, 1)
    assert.equals(#beta, 1)
    assert.near(alpha[1].value, 10, 0.001)
    assert.near(beta[1].value, 20, 0.001)
  end)
end)
