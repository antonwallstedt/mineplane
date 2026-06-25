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

-- ─── Rpc.serve_step ───────────────────────────────────────────────────────────

describe("Rpc.serve_step", function()
  it("rejects non-table transport", function()
    assert.error_matches(
      function() Rpc.serve_step("bad", {}) end,
      "transport must be a table"
    )
  end)

  it("rejects non-table handlers", function()
    local t = { send = function() end, receive = function() end }
    assert.error_matches(function() Rpc.serve_step(t, "bad") end, "handlers must be a table")
  end)

  it("returns false when inbox is empty", function()
    local _, server = fakes.make_loopback_pair()
    assert.equals(Rpc.serve_step(server, {}), false)
  end)

  it("discards non-request messages", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 1, type = Rpc.TYPE.RESPONSE, payload = "ignored" })
    assert.equals(Rpc.serve_step(server, {}), false)
  end)

  it("discards malformed messages (no type field)", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 1, payload = "no type" })
    assert.equals(Rpc.serve_step(server, {}), false)
  end)

  it("dispatches a request and sends a response", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 7, type = Rpc.TYPE.REQUEST, method = "ping", payload = "hi" })
    Rpc.serve_step(server, {
      ping = function(payload) return "pong:" .. payload end,
    })
    local _, response = caller.receive()
    assert.equals(response.id,      7)
    assert.equals(response.type,    Rpc.TYPE.RESPONSE)
    assert.equals(response.payload, "pong:hi")
  end)

  it("passes sender_id to the handler", function()
    local caller, server = fakes.make_loopback_pair()
    local received_sender
    caller.send(0, { id = 1, type = Rpc.TYPE.REQUEST, method = "who", payload = nil })
    Rpc.serve_step(server, {
      who = function(_payload, sender_id)
        received_sender = sender_id
        return true
      end,
    })
    assert.equals(received_sender, 1)  -- server.receive() returns partner_id=1 (caller's id)
  end)

  it("returns TYPE.ERROR for unknown method", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 3, type = Rpc.TYPE.REQUEST, method = "nope", payload = nil })
    Rpc.serve_step(server, {})
    local _, response = caller.receive()
    assert.equals(response.type, Rpc.TYPE.ERROR)
    assert.truthy(response.payload:find("unknown method"))
  end)

  it("pcall-isolates a crashing handler and sends TYPE.ERROR", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 2, type = Rpc.TYPE.REQUEST, method = "boom", payload = nil })
    Rpc.serve_step(server, {
      boom = function() error("kaboom") end,
    })
    local _, response = caller.receive()
    assert.equals(response.type, Rpc.TYPE.ERROR)
    assert.truthy(response.payload:find("kaboom"))
  end)

  it("calls on_error hook when handler crashes", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 2, type = Rpc.TYPE.REQUEST, method = "boom", payload = nil })
    local error_method, error_msg
    Rpc.serve_step(server, {
      boom = function() error("kaboom") end,
    }, {
      on_error = function(method, err)
        error_method = method
        error_msg    = err
      end,
    })
    assert.equals(error_method, "boom")
    assert.truthy(error_msg:find("kaboom"))
  end)

  it("does not call on_error on success", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 1, type = Rpc.TYPE.REQUEST, method = "ok", payload = nil })
    local called = false
    Rpc.serve_step(server, {
      ok = function() return true end,
    }, {
      on_error = function() called = true end,
    })
    assert.falsy(called)
  end)

  it("continue processing after a handler crash (loop resilience)", function()
    local caller, server = fakes.make_loopback_pair()
    caller.send(0, { id = 1, type = Rpc.TYPE.REQUEST, method = "crash", payload = nil })
    caller.send(0, { id = 2, type = Rpc.TYPE.REQUEST, method = "ok",    payload = nil })
    Rpc.serve_step(server, { crash = function() error("x") end })
    Rpc.serve_step(server, { ok    = function() return "fine" end })
    local _, r1 = caller.receive()
    local _, r2 = caller.receive()
    assert.equals(r1.type, Rpc.TYPE.ERROR)
    assert.equals(r2.type, Rpc.TYPE.RESPONSE)
  end)
end)
