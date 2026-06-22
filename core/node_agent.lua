--- Worker-side registration and heartbeat agent.
--- Two-phase: unregistered → broadcast REGISTER and wait for ACK;
---            registered   → send HEARTBEAT directly to master_id.
--- Re-registers automatically after miss_limit missed heartbeats.
---
--- ctx shape: { os = { sleep = function(n), epoch = function(unit) } }
--- transport shape: { send(id, msg), broadcast(msg), receive(timeout) → id, msg }

local NodeAgent = {}
NodeAgent.__index = NodeAgent

local DEFAULT_INTERVAL   = 15
local DEFAULT_MISS_LIMIT = 3
local ACK_TIMEOUT        = 5

--- @param ctx          table   { os = { sleep, epoch } }
--- @param computer_id  number  injected (os.getComputerID() at call site)
--- @param transport    table   { send, broadcast, receive }
--- @param opts         table?  { interval_seconds?, miss_limit?, label?, labels? }
--- @return NodeAgent
function NodeAgent.new(ctx, computer_id, transport, opts)
  assert(type(ctx) == "table" and type(ctx.os) == "table", "ctx.os required")
  assert(type(computer_id) == "number", "computer_id must be a number")
  assert(type(transport) == "table", "transport must be a table")
  opts = opts or {}
  local self = setmetatable({}, NodeAgent)
  self._ctx         = ctx
  self._id          = computer_id
  self._transport   = transport
  self._interval    = opts.interval_seconds or DEFAULT_INTERVAL
  self._miss_limit  = opts.miss_limit       or DEFAULT_MISS_LIMIT
  self._label       = opts.label  or ""
  self._labels      = opts.labels or {}
  self._registered  = false
  self._master_id   = nil
  self._miss_count  = 0
  return self
end

--- @return boolean
function NodeAgent:registered()
  return self._registered
end

local function make_register_msg(self)
  return { type = "REGISTER", id = self._id, label = self._label, labels = self._labels }
end

--- One agent iteration. Broadcasts REGISTER or sends HEARTBEAT, then sleeps.
--- @return number  current epoch seconds
function NodeAgent:step()
  local now = self._ctx.os.epoch("utc") / 1000

  if not self._registered then
    self._transport.broadcast(make_register_msg(self))
    local _, ack = self._transport.receive(ACK_TIMEOUT)
    if ack and ack.type == "ACK" then
      self._master_id  = ack.master_id
      self._registered = true
      self._miss_count = 0
    end
  else
    self._transport.send(self._master_id, { type = "HEARTBEAT", id = self._id })
    local _, ack = self._transport.receive(ACK_TIMEOUT)
    if ack and ack.type == "ACK" then
      self._miss_count = 0
    else
      self._miss_count = self._miss_count + 1
      if self._miss_count >= self._miss_limit then
        self._registered = false
        self._master_id  = nil
        self._miss_count = 0
      end
    end
  end

  self._ctx.os.sleep(self._interval)
  return now
end

--- Self-restarting run loop with exponential backoff.
function NodeAgent:run()
  local backoff = 1
  while true do
    local ok, err = pcall(function() self:step() end)
    if ok then
      backoff = 1
    else
      _ = err
      self._ctx.os.sleep(backoff)
      backoff = math.min(backoff * 2, 60)
    end
  end
end

return NodeAgent
