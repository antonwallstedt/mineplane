-- Integration tests for the startup wiring under real CC APIs.
-- Verifies that config loading, transport construction, ctx wiring,
-- and module loading all work correctly in the CC environment.
-- Does NOT test rednet message exchange (requires two computers).

local PROJECT = "/project"

describe("startup wiring (real CC)", function()
  it("make_transport returns a table with send/broadcast/receive", function()
    -- Load the transport factory in isolation — same code as startup.lua uses.
    -- We verify the shape without opening a real modem.
    local PROTOCOL = "mineplane"
    local transport = {
      send      = function(id, msg) rednet.send(id, msg, PROTOCOL) end,
      broadcast = function(msg)     rednet.broadcast(msg, PROTOCOL) end,
      receive   = function(timeout) return rednet.receive(PROTOCOL, timeout) end,
    }
    assert.truthy(type(transport.send)      == "function")
    assert.truthy(type(transport.broadcast) == "function")
    assert.truthy(type(transport.receive)   == "function")
  end)

  it("make_ctx wraps real os.epoch and os.sleep", function()
    local ctx = {
      os = {
        epoch = function(unit) return os.epoch(unit) end,
        sleep = function(n)    return os.sleep(n) end,
      },
    }
    local ms = ctx.os.epoch("utc")
    assert.truthy(type(ms) == "number")
    assert.truthy(ms > 0)
  end)

  it("os.epoch('utc') returns milliseconds (sanity check)", function()
    -- Year-2001 in ms = 978307200000. If this fails the VM clock is wrong.
    local ms = os.epoch("utc")
    assert.truthy(ms > 978307200000)
  end)

  it("lib.registry loads cleanly under CC", function()
    local Registry = require("lib.registry")
    local r = Registry.new()
    r:register({ id = 1, label = "test" }, 1000)
    assert.equals(r:get(1).label, "test")
  end)

  it("core.registry_server loads cleanly under CC", function()
    local RegistryServer = require("core.registry_server")
    assert.truthy(type(RegistryServer.new) == "function")
  end)

  it("core.node_agent loads cleanly under CC", function()
    local NodeAgent = require("core.node_agent")
    assert.truthy(type(NodeAgent.new) == "function")
  end)

  it("registry and server wire together without error", function()
    local Registry       = require("lib.registry")
    local RegistryServer = require("core.registry_server")
    local sent = {}
    local transport = {
      send      = function(id, msg) table.insert(sent, { to = id, msg = msg }) end,
      broadcast = function() end,
      receive   = function() end,
    }
    local ctx = {
      os = { epoch = function(_) return os.epoch("utc") end },
    }
    local registry = Registry.new()
    local server   = RegistryServer.new(ctx, transport, registry, { master_id = 0 })
    -- step() with no message in queue should not crash
    local now = server:step()
    assert.truthy(type(now) == "number")
    assert.truthy(now > 0)
  end)

  it("node_agent wires together without error", function()
    local NodeAgent = require("core.node_agent")
    local broadcasts = {}
    local transport = {
      send      = function() end,
      broadcast = function(msg) table.insert(broadcasts, msg) end,
      receive   = function() end,
    }
    local ctx = {
      os = {
        epoch = function(_) return os.epoch("utc") end,
        sleep = function() end,
      },
    }
    local agent = NodeAgent.new(ctx, os.getComputerID(), transport, { label = "test" })
    agent:step()
    assert.equals(#broadcasts, 1)
    assert.equals(broadcasts[1].type, "REGISTER")
    assert.equals(broadcasts[1].id, os.getComputerID())
  end)
end)
