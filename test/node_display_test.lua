local NodeDisplay = require("core.node_display")
local Registry    = require("lib.registry")
local fakes       = require("test.support.fakes")

local function make_display(epoch_ms, opts)
  local ctx      = fakes.make_ctx(epoch_ms)
  local monitor  = fakes.make_monitor()
  local registry = Registry.new()
  local nd       = NodeDisplay.new(ctx, monitor, registry, opts)
  return nd, monitor, registry
end

describe("NodeDisplay", function()
  it("step() calls monitor.clear()", function()
    local nd, mon = make_display(5000000)
    nd:step()
    assert.equals(mon._cleared(), 1)
  end)

  it("step() calls setTextScale with default 0.5", function()
    local nd, mon = make_display(5000000)
    nd:step()
    assert.equals(mon._scale(), 0.5)
  end)

  it("step() calls setTextScale with configured value", function()
    local nd, mon = make_display(5000000, { text_scale = 1 })
    nd:step()
    assert.equals(mon._scale(), 1)
  end)

  it("step() returns epoch seconds", function()
    local nd = make_display(7500000)
    local now = nd:step()
    assert.equals(now, 7500)
  end)

  it("step() sleeps for refresh_seconds", function()
    local slept = {}
    local ctx = { os = {
      epoch = function(_) return 5000000 end,
      sleep = function(n) table.insert(slept, n) end,
    }}
    local nd = NodeDisplay.new(ctx, fakes.make_monitor(), Registry.new(), { refresh_seconds = 10 })
    nd:step()
    assert.equals(#slept, 1)
    assert.equals(slept[1], 10)
  end)

  it("empty registry renders without error", function()
    local nd, mon = make_display(5000000)
    local ok = pcall(function() nd:step() end)
    assert.truthy(ok)
  end)

  it("Ready node has 'Ready' in written output", function()
    local nd, mon, registry = make_display(5000000)
    registry:register({ id = 1, label = "farm" }, 5000)
    nd:step()
    local found = false
    for _, text in ipairs(mon._written()) do
      if text:find("Ready") then found = true; break end
    end
    assert.truthy(found)
  end)

  it("NotReady node has 'NotReady' in written output", function()
    local nd, mon, registry = make_display(5000000, nil)
    registry:register({ id = 1, label = "farm" }, 4950)
    registry:tick(5000)  -- age=50s > timeout=45, still within eviction=300
    nd:step()
    local found = false
    for _, text in ipairs(mon._written()) do
      if text:find("NotReady") then found = true; break end
    end
    assert.truthy(found)
  end)

  it("renders one row per node", function()
    local nd, mon, registry = make_display(5000000)
    registry:register({ id = 1, label = "alpha" }, 5000)
    registry:register({ id = 2, label = "beta"  }, 5000)
    nd:step()
    local node_rows = 0
    for _, text in ipairs(mon._written()) do
      if text:find("alpha") or text:find("beta") then
        node_rows = node_rows + 1
      end
    end
    assert.equals(node_rows, 2)
  end)

  it("age column reflects time since last_seen", function()
    local nd, mon, registry = make_display(5000000)
    registry:register({ id = 1, label = "farm" }, 4940)
    nd:step()
    local found = false
    for _, text in ipairs(mon._written()) do
      if text:find("60s") or text:find("1m") then found = true; break end
    end
    assert.truthy(found)
  end)
end)
