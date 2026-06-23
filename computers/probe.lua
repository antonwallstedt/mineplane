-- Mineplane rednet probe — run this interactively in CraftOS-PC to verify
-- modem and rednet wiring before a full two-computer test.
--
-- Usage (from the CraftOS shell, with /project mounted):
--   dofile("/project/computers/probe.lua")
--
-- Or paste directly into the Lua REPL:
--   lua
--   > dofile("/project/computers/probe.lua")

local PROTOCOL = "mineplane"
local LISTEN_SECONDS = 3

local function pass(msg)
  print("  [OK] " .. msg)
end
local function fail(msg)
  printError("  [FAIL] " .. msg)
end
local function info(msg)
  print("  [--] " .. msg)
end
local function section(title)
  print("")
  print("-- " .. title .. " " .. string.rep("-", 40 - #title))
end

-- ── 1. identity ───────────────────────────────────────────────────────────────

section("identity")
local my_id = os.getComputerID()
local my_label = os.getComputerLabel() or "(none)"
info("computer id    = " .. my_id)
info("computer label = " .. my_label)
info("os.epoch('utc') = " .. os.epoch("utc") .. " ms")

-- ── 2. modem discovery ────────────────────────────────────────────────────────

section("modem discovery")

local modem_name, modem
for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "modem" then
    modem_name = side
    modem = peripheral.wrap(side)
    break
  end
end

if modem then
  pass("modem found on side: " .. modem_name)
  info("isWireless() = " .. tostring(modem.isWireless()))
else
  fail("no modem found")
  print("")
  print("  Attach one with:  attach left modem")
  print("  Then re-run this script.")
  return
end

-- ── 3. rednet open ────────────────────────────────────────────────────────────

section("rednet open")

local ok, err = pcall(rednet.open, modem_name)
if ok then
  pass("rednet.open('" .. modem_name .. "') succeeded")
  info("rednet.isOpen('" .. modem_name .. "') = " .. tostring(rednet.isOpen(modem_name)))
else
  fail("rednet.open failed: " .. tostring(err))
  return
end

-- ── 4. broadcast ──────────────────────────────────────────────────────────────

section("broadcast")

local msg = { type = "REGISTER", id = my_id, label = "probe", labels = { type = "probe" } }
local broadcast_ok, broadcast_err = pcall(rednet.broadcast, msg, PROTOCOL)
if broadcast_ok then
  pass("rednet.broadcast sent REGISTER message on protocol '" .. PROTOCOL .. "'")
else
  fail("rednet.broadcast failed: " .. tostring(broadcast_err))
end

-- ── 5. transport table shape ──────────────────────────────────────────────────

section("transport table (shape check)")

local transport = {
  send = function(id, m)
    rednet.send(id, m, PROTOCOL)
  end,
  broadcast = function(m)
    rednet.broadcast(m, PROTOCOL)
  end,
  receive = function(t)
    return rednet.receive(PROTOCOL, t)
  end,
}

local shape_ok = type(transport.send) == "function"
  and type(transport.broadcast) == "function"
  and type(transport.receive) == "function"
if shape_ok then
  pass("transport table has correct shape")
else
  fail("transport table shape wrong")
end

-- test receive call (will return nil after timeout — that's fine)
local recv_ok, sender, incoming = pcall(transport.receive, 0)
if recv_ok then
  pass("transport.receive(0) callable without error")
  if sender then
    info("unexpected message from " .. tostring(sender) .. ": " .. textutils.serialise(incoming))
  end
else
  fail("transport.receive raised: " .. tostring(sender))
end

-- ── 6. listen for incoming ────────────────────────────────────────────────────

section("listen (" .. LISTEN_SECONDS .. "s - run a second computer to send REGISTER)")

info("waiting " .. LISTEN_SECONDS .. "s for any '" .. PROTOCOL .. "' message ...")
local sender_id, received = rednet.receive(PROTOCOL, LISTEN_SECONDS)

if sender_id then
  pass("received message from computer " .. tostring(sender_id))
  print("  " .. textutils.serialise(received))
else
  info("nothing received (expected if only one computer is running)")
end

-- ── summary ───────────────────────────────────────────────────────────────────

section("summary")
print("")
print("Modem and rednet wiring looks good on this computer.")
print("To test two-computer comms:")
print("  1. Open a second computer in CraftOS-PC")
print("  2. Run this probe on both at roughly the same time")
print("  3. The listen step should show the other computer's REGISTER message")
print("")
