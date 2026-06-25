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
