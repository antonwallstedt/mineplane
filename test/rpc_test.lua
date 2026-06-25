local Rpc   = require("lib.rpc")
local fakes = require("test.support.fakes")

-- ─── Rpc.TYPE ─────────────────────────────────────────────────────────────────

describe("Rpc.TYPE", function()
  it("has REQUEST=1, RESPONSE=2, ERROR=3", function()
    assert.equals(Rpc.TYPE.REQUEST,  1)
    assert.equals(Rpc.TYPE.RESPONSE, 2)
    assert.equals(Rpc.TYPE.ERROR,    3)
  end)

  it("is read-only", function()
    assert.error_matches(function() Rpc.TYPE.REQUEST = 99 end, "read%-only")
  end)

  it("raises on undefined key", function()
    assert.error_matches(function() return Rpc.TYPE.REQEUST end, "undefined")
  end)
end)

-- ─── Rpc.new ──────────────────────────────────────────────────────────────────

describe("Rpc.new", function()
  it("rejects nil transport", function()
    assert.error_matches(function() Rpc.new(nil) end, "transport must be a table")
  end)

  it("rejects transport missing send", function()
    assert.error_matches(
      function() Rpc.new({ receive = function() end }) end,
      "transport.send must be a function"
    )
  end)

  it("rejects transport missing receive", function()
    assert.error_matches(
      function() Rpc.new({ send = function() end }) end,
      "transport.receive must be a function"
    )
  end)

  it("constructs with a valid transport", function()
    local rpc = Rpc.new({ send = function() end, receive = function() end })
    assert.truthy(rpc)
  end)

  it("accepts an injected clock", function()
    local clock_calls = 0
    local rpc = Rpc.new(
      { send = function() end, receive = function() end },
      { clock = function() clock_calls = clock_calls + 1; return 0 end }
    )
    assert.truthy(rpc)
  end)
end)

-- ─── fakes.make_loopback_pair ─────────────────────────────────────────────────

describe("fakes.make_loopback_pair", function()
  it("send on a lands in b inbox", function()
    local a, b = fakes.make_loopback_pair()
    a.send(0, { value = "hello" })
    local from, msg = b.receive()
    assert.equals(msg.value, "hello")
    assert.equals(from, 1)  -- b.receive() returns a's partner_id=1
  end)

  it("send on b lands in a inbox", function()
    local a, b = fakes.make_loopback_pair()
    b.send(0, { value = "world" })
    local from, msg = a.receive()
    assert.equals(msg.value, "world")
    assert.equals(from, 2)  -- a.receive() returns b's partner_id=2
  end)

  it("receive on empty inbox returns nil", function()
    local a, _ = fakes.make_loopback_pair()
    local from, msg = a.receive()
    assert.is_nil(from)
    assert.is_nil(msg)
  end)

  it("messages are dequeued in FIFO order", function()
    local a, b = fakes.make_loopback_pair()
    a.send(0, { n = 1 })
    a.send(0, { n = 2 })
    local _, first  = b.receive()
    local _, second = b.receive()
    assert.equals(first.n,  1)
    assert.equals(second.n, 2)
  end)

  it("the two transports do not share inboxes", function()
    local a, b = fakes.make_loopback_pair()
    a.send(0, { side = "a" })
    b.send(0, { side = "b" })
    local _, msg_b = b.receive()
    local _, msg_a = a.receive()
    assert.equals(msg_b.side, "a")
    assert.equals(msg_a.side, "b")
  end)
end)
