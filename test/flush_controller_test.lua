local FlushController = require("core.flush_controller")

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

local function make_tsdb()
  local flushes = {}
  return {
    flush = function(_, now) table.insert(flushes, now) end,
    flushes = flushes,
  }
end

-- ─── construction ─────────────────────────────────────────────────────────────

describe("FlushController.new", function()
  it("rejects missing ctx.os", function()
    assert.error_matches(function()
      FlushController.new({}, 60)
    end, "ctx.os is required")
  end)

  it("rejects non-positive interval", function()
    assert.error_matches(function()
      FlushController.new(make_ctx(), 0)
    end, "interval_seconds")
  end)

  it("constructs with valid args", function()
    assert.truthy(FlushController.new(make_ctx(), 60))
  end)
end)

-- ─── register ─────────────────────────────────────────────────────────────────

describe("FlushController:register", function()
  it("returns self for chaining", function()
    local fc = FlushController.new(make_ctx(), 60)
    local tsdb = make_tsdb()
    assert.equals(fc:register(tsdb), fc)
  end)

  it("accepts multiple registrations via chaining", function()
    local ctx = make_ctx(3000000)
    local fc = FlushController.new(ctx, 60)
    local a, b = make_tsdb(), make_tsdb()
    fc:register(a):register(b)
    fc:step()
    assert.equals(#a.flushes, 1)
    assert.equals(#b.flushes, 1)
  end)
end)

-- ─── step ─────────────────────────────────────────────────────────────────────

describe("FlushController:step", function()
  it("sleeps for the configured interval", function()
    local ctx = make_ctx()
    local fc = FlushController.new(ctx, 30)
    fc:step()
    assert.equals(ctx.sleeps[1], 30)
  end)

  it("flushes all registered TSDBs", function()
    local ctx = make_ctx()
    local fc = FlushController.new(ctx, 60)
    local a, b, c = make_tsdb(), make_tsdb(), make_tsdb()
    fc:register(a):register(b):register(c)
    fc:step()
    assert.equals(#a.flushes, 1)
    assert.equals(#b.flushes, 1)
    assert.equals(#c.flushes, 1)
  end)

  it("passes epoch seconds (not ms) to flush", function()
    local ctx = make_ctx(7500000)  -- 7,500,000 ms = 7500 seconds
    local fc = FlushController.new(ctx, 60)
    local tsdb = make_tsdb()
    fc:register(tsdb)
    local now = fc:step()
    assert.near(now, 7500, 0.001)
    assert.near(tsdb.flushes[1], 7500, 0.001)
  end)

  it("with no registered TSDBs is a no-op beyond sleeping", function()
    local ctx = make_ctx()
    local fc = FlushController.new(ctx, 60)
    fc:step()
    assert.equals(#ctx.sleeps, 1)
  end)

  it("flushes each TSDB with the same timestamp", function()
    local ctx = make_ctx(10000000)
    local fc = FlushController.new(ctx, 60)
    local a, b = make_tsdb(), make_tsdb()
    fc:register(a):register(b)
    fc:step()
    assert.equals(a.flushes[1], b.flushes[1])
  end)
end)
