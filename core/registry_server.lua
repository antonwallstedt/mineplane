--- Master-side registry controller.
--- Blocks on transport.receive(tick_interval) — the timeout IS the tick interval.
--- Dispatches REGISTER/HEARTBEAT messages, sends ACK, calls registry:tick().
---
--- ctx shape: { os = { epoch = function(unit) } }
--- transport shape: { send(id, msg), broadcast(msg), receive(timeout) → id, msg }

local RegistryServer = {}
RegistryServer.__index = RegistryServer

local DEFAULT_TICK_INTERVAL = 5

--- @param ctx        table     { os = { epoch } }
--- @param transport  table     { send, broadcast, receive }
--- @param registry   Registry  lib/registry instance
--- @param opts       table?    { tick_interval?, master_id? }
--- @return RegistryServer
function RegistryServer.new(ctx, transport, registry, opts)
  assert(type(ctx) == "table" and type(ctx.os) == "table", "ctx.os required")
  assert(type(transport) == "table", "transport must be a table")
  assert(type(registry) == "table", "registry must be a table")
  opts = opts or {}
  local self = setmetatable({}, RegistryServer)
  self._ctx           = ctx
  self._transport     = transport
  self._registry      = registry
  self._tick_interval = opts.tick_interval or DEFAULT_TICK_INTERVAL
  self._master_id     = opts.master_id or 0
  return self
end

--- One event loop iteration.
--- Waits up to tick_interval seconds for a message, dispatches it, then ticks.
--- @return number  current epoch seconds
function RegistryServer:step()
  local now = self._ctx.os.epoch("utc") / 1000

  local sender, msg = self._transport.receive(self._tick_interval)
  if msg then
    if msg.type == "REGISTER" then
      self._registry:register({
        id     = msg.id,
        label  = msg.label,
        node   = msg.node,
        labels = msg.labels,
      }, now)
      self._transport.send(sender, { type = "ACK", master_id = self._master_id })
    elseif msg.type == "HEARTBEAT" then
      self._registry:heartbeat(msg.id, now)
    end
    -- unknown types are silently ignored
  end

  self._registry:tick(now)
  return now
end

--- Self-restarting run loop with exponential backoff.
function RegistryServer:run()
  local backoff = 1
  while true do
    local ok, err = pcall(function() self:step() end)
    if ok then
      backoff = 1
    else
      -- err surfaced for logging; backoff before retry
      _ = err
      self._ctx.os.sleep(backoff)
      backoff = math.min(backoff * 2, 60)
    end
  end
end

return RegistryServer
