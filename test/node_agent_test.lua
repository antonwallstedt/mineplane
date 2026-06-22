local NodeAgent = require("core.node_agent")
local fakes     = require("test.support.fakes")

local function make_agent(epoch_ms, transport_override, opts)
  local ctx       = fakes.make_ctx(epoch_ms)
  local transport = transport_override or fakes.make_transport()
  local agent     = NodeAgent.new(ctx, 7, transport, opts)
  return agent, transport
end

describe("NodeAgent", function()
  it("starts unregistered", function()
    local agent = make_agent(1000000)
    assert.falsy(agent:registered())
  end)

  it("first step broadcasts REGISTER", function()
    local agent, transport = make_agent(1000000)
    agent:step()
    assert.equals(#transport._broadcasts, 1)
    local msg = transport._broadcasts[1]
    assert.equals(msg.type, "REGISTER")
    assert.equals(msg.id, 7)
  end)

  it("REGISTER includes label and labels from opts", function()
    local transport = fakes.make_transport()
    local agent = NodeAgent.new(
      fakes.make_ctx(1000000),
      7,
      transport,
      { label = "farm-east", labels = { type = "turtle" } }
    )
    agent:step()
    local msg = transport._broadcasts[1]
    assert.equals(msg.label, "farm-east")
    assert.equals(msg.labels.type, "turtle")
  end)

  it("ACK on first step sets registered() true", function()
    local transport = fakes.make_transport()
    transport.inject(1, { type = "ACK", master_id = 1 })
    local agent = NodeAgent.new(fakes.make_ctx(1000000), 7, transport)
    agent:step()
    assert.truthy(agent:registered())
  end)

  it("after ACK, next step sends HEARTBEAT to master_id", function()
    local transport = fakes.make_transport()
    transport.inject(1, { type = "ACK", master_id = 1 })
    local agent = NodeAgent.new(fakes.make_ctx(1000000), 7, transport)
    agent:step()
    -- inject another ACK for the heartbeat receive call
    transport.inject(1, { type = "ACK", master_id = 1 })
    agent:step()
    local heartbeats = {}
    for _, s in ipairs(transport._sent) do
      if s.msg.type == "HEARTBEAT" then
        table.insert(heartbeats, s)
      end
    end
    assert.equals(#heartbeats, 1)
    assert.equals(heartbeats[1].to, 1)
    assert.equals(heartbeats[1].msg.id, 7)
  end)

  it("miss_limit consecutive non-ACK heartbeats causes re-registration", function()
    local transport = fakes.make_transport()
    -- initial ACK to register
    transport.inject(1, { type = "ACK", master_id = 1 })
    local agent = NodeAgent.new(
      fakes.make_ctx(1000000), 7, transport, { miss_limit = 3 }
    )
    agent:step()
    assert.truthy(agent:registered())
    -- three missed heartbeats (no ACK in inbox)
    agent:step()
    agent:step()
    agent:step()
    assert.falsy(agent:registered())
  end)

  it("successful heartbeat ACK resets miss counter", function()
    local transport = fakes.make_transport()
    transport.inject(1, { type = "ACK", master_id = 1 })
    local agent = NodeAgent.new(
      fakes.make_ctx(1000000), 7, transport, { miss_limit = 3 }
    )
    agent:step()
    -- two missed heartbeats
    agent:step()
    agent:step()
    -- one successful ACK
    transport.inject(1, { type = "ACK", master_id = 1 })
    agent:step()
    -- two more misses — should NOT yet reach miss_limit=3 (counter reset)
    agent:step()
    agent:step()
    assert.truthy(agent:registered())
  end)

  it("step returns epoch seconds", function()
    local agent = make_agent(9000000)
    local now = agent:step()
    assert.equals(now, 9000)
  end)

  it("step calls sleep with interval_seconds", function()
    local slept = {}
    local ctx = {
      os = {
        epoch = function(_) return 1000000 end,
        sleep = function(n) table.insert(slept, n) end,
      },
    }
    local agent = NodeAgent.new(ctx, 7, fakes.make_transport(), { interval_seconds = 30 })
    agent:step()
    assert.equals(#slept, 1)
    assert.equals(slept[1], 30)
  end)
end)
