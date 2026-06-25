--- CraftOS-PC integration tests for lib/rpc.lua.
--- Requires: parallel.waitForAll, rednet, os.pullEvent (CC globals).
--- Run via CraftOS-PC headless in CI — NOT with lua test/runner.lua.
---
--- To run manually in CraftOS-PC:
---   dofile("test/cc/rpc_integration_test.lua")

local Rpc = require("lib.rpc")

local MODEM_SIDE  = "top"    -- adjust to your CraftOS-PC setup
local SERVER_ID   = os.getComputerID()  -- loopback: same computer

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("[PASS] " .. name)
    passed = passed + 1
  else
    print("[FAIL] " .. name .. ": " .. tostring(err))
    failed = failed + 1
  end
end

-- ─── basic request/response ───────────────────────────────────────────────────

test("call() gets response from serve() over real rednet", function()
  local result_holder = {}

  parallel.waitForAll(
    function()
      -- server coroutine: handle one ping then stop
      local server_transport = Rpc.rednet_transport(MODEM_SIDE)
      Rpc.serve_step(server_transport, {
        ping = function(payload) return "pong:" .. tostring(payload) end,
      })
    end,
    function()
      -- caller coroutine
      os.sleep(0.05)  -- brief yield so server is ready
      local caller_transport = Rpc.rednet_transport(MODEM_SIDE)
      local rpc = Rpc.new(caller_transport)
      local ok, result = rpc:call(SERVER_ID, "ping", "hello", { timeout = 5, attempts = 3 })
      result_holder.ok     = ok
      result_holder.result = result
    end
  )

  assert(result_holder.ok == true,            "expected ok=true, got " .. tostring(result_holder.ok))
  assert(result_holder.result == "pong:hello","expected pong:hello, got " .. tostring(result_holder.result))
end)

-- ─── error response ───────────────────────────────────────────────────────────

test("TYPE.ERROR from handler is returned without retry", function()
  local send_count = 0
  local result_holder = {}

  parallel.waitForAll(
    function()
      local server_transport = Rpc.rednet_transport(MODEM_SIDE)
      Rpc.serve_step(server_transport, {
        boom = function() error("intentional failure") end,
      })
    end,
    function()
      os.sleep(0.05)
      local caller_transport = Rpc.rednet_transport(MODEM_SIDE)
      local original_send = caller_transport.send
      caller_transport.send = function(id, msg)
        send_count = send_count + 1
        original_send(id, msg)
      end
      local rpc = Rpc.new(caller_transport)
      local ok, err = rpc:call(SERVER_ID, "boom", {}, { timeout = 5, attempts = 3 })
      result_holder.ok  = ok
      result_holder.err = err
    end
  )

  assert(result_holder.ok == false,                "expected ok=false")
  assert(result_holder.err:find("intentional"),    "expected error message to contain 'intentional'")
  assert(send_count == 1,                          "expected 1 send (no retry on error), got " .. send_count)
end)

-- ─── timeout ──────────────────────────────────────────────────────────────────

test("call() returns timeout after attempts exhausted (no server)", function()
  -- No server running — all attempts time out
  local caller_transport = Rpc.rednet_transport(MODEM_SIDE)
  local rpc = Rpc.new(caller_transport)
  local ok, err = rpc:call(SERVER_ID + 1, "ping", {}, { timeout = 1, attempts = 2 })
  assert(ok == false, "expected ok=false")
  assert(err == "timeout", "expected 'timeout', got " .. tostring(err))
end)

-- ─── summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error("integration tests failed") end
