--- Reliable request/response over CC rednet (or any injectable transport).
--- Caller side: Rpc object with call(). Server side: Rpc.serve_step / Rpc.serve.

local Rpc = {}
Rpc.__index = Rpc

-- ─── TYPE constants ───────────────────────────────────────────────────────────

--- @alias RpcMessageType
--- | 1  # REQUEST
--- | 2  # RESPONSE
--- | 3  # ERROR

local type_values = {
  REQUEST  = 1,
  RESPONSE = 2,
  ERROR    = 3,
}

Rpc.TYPE = setmetatable({}, {
  __newindex = function() error("Rpc.TYPE is read-only") end,
  __index    = function(_, k)
    if type_values[k] then
      return type_values[k]
    end
    error("Rpc.TYPE." .. k .. " is undefined")
  end,
})

--- @class RpcMessage
--- @field id      integer
--- @field type    RpcMessageType
--- @field method  string|nil      present on REQUEST only
--- @field payload any

-- ─── constructor ──────────────────────────────────────────────────────────────

--- @param transport  table     { send(target_id, msg), receive(timeout_s)->sender_id,msg }
--- @param opts       table|nil { clock: fun()->number }  clock defaults to os.time
--- @return Rpc
function Rpc.new(transport, opts)
  assert(type(transport) == "table", "transport must be a table")
  assert(type(transport.send) == "function", "transport.send must be a function")
  assert(type(transport.receive) == "function", "transport.receive must be a function")
  opts = opts or {}
  local self = setmetatable({}, Rpc)
  self._transport = transport
  self._clock     = opts.clock or os.time
  self._txns      = {}
  self._next_id   = 1
  return self
end

-- ─── transaction controller (internal) ───────────────────────────────────────

function Rpc:_txn_create(timeout_s)
  local id = self._next_id
  self._next_id = self._next_id + 1
  self._txns[id] = { expiry = self._clock() + timeout_s }
  return id
end

function Rpc:_txn_resolve(id)
  local txn = self._txns[id]
  if not txn then return nil end
  self._txns[id] = nil
  return txn
end

function Rpc:_txn_cleanup()
  local now = self._clock()
  for id, txn in pairs(self._txns) do
    if now >= txn.expiry then self._txns[id] = nil end
  end
end

-- ─── call ─────────────────────────────────────────────────────────────────────

local CALL_DEFAULTS = { timeout = 5, attempts = 3 }

--- @param target_id  integer
--- @param method     string
--- @param payload    any
--- @param opts       table|nil  { timeout: number, attempts: integer }
--- @return boolean, any  ok, result_or_error
function Rpc:call(target_id, method, payload, opts)
  assert(type(target_id) == "number", "target_id must be a number")
  assert(type(method) == "string" and method ~= "", "method must be a non-empty string")
  opts = opts or {}
  local timeout     = opts.timeout  or CALL_DEFAULTS.timeout
  local attempts    = opts.attempts or CALL_DEFAULTS.attempts
  local per_attempt = timeout / attempts

  for _ = 1, attempts do
    local id = self:_txn_create(per_attempt)
    self._transport.send(target_id, {
      id      = id,
      type    = Rpc.TYPE.REQUEST,
      method  = method,
      payload = payload,
    })

    local deadline = self._clock() + per_attempt
    while true do
      local remaining = deadline - self._clock()
      if remaining <= 0 then break end
      local _sender, msg = self._transport.receive(remaining)
      if msg == nil then break end
      if msg.id == id then
        self:_txn_resolve(id)
        if msg.type == Rpc.TYPE.RESPONSE then
          return true, msg.payload
        elseif msg.type == Rpc.TYPE.ERROR then
          return false, msg.payload
        end
      end
    end
    self:_txn_resolve(id)
  end

  self:_txn_cleanup()
  return false, "timeout"
end

-- ─── serve_step / serve ───────────────────────────────────────────────────────

--- Process one pending message. Returns true if a request was dispatched.
--- Consistent with ScrapeController.step() — testable single iteration.
--- @param transport  table
--- @param handlers   table  { [method]: fun(payload, sender_id)->any }
--- @param opts       table|nil  { on_error: fun(method, err) }
--- @return boolean
function Rpc.serve_step(transport, handlers, opts)
  assert(type(transport) == "table", "transport must be a table")
  assert(type(transport.send) == "function", "transport.send must be a function")
  assert(type(transport.receive) == "function", "transport.receive must be a function")
  assert(type(handlers) == "table", "handlers must be a table")
  opts = opts or {}

  local sender_id, msg = transport.receive()
  if msg == nil or type(msg) ~= "table" or msg.type ~= Rpc.TYPE.REQUEST then
    return false
  end

  local handler = handlers[msg.method]
  if not handler then
    transport.send(sender_id, {
      id      = msg.id,
      type    = Rpc.TYPE.ERROR,
      payload = "unknown method: " .. tostring(msg.method),
    })
    return true
  end

  local ok, result = pcall(handler, msg.payload, sender_id)
  if ok then
    transport.send(sender_id, {
      id      = msg.id,
      type    = Rpc.TYPE.RESPONSE,
      payload = result,
    })
  else
    transport.send(sender_id, {
      id      = msg.id,
      type    = Rpc.TYPE.ERROR,
      payload = result,
    })
    if opts.on_error then opts.on_error(msg.method, result) end
  end
  return true
end

--- Blocking serve loop — run as a coroutine via parallel.waitForAll.
--- @param transport  table
--- @param handlers   table
--- @param opts       table|nil
function Rpc.serve(transport, handlers, opts)
  while true do
    Rpc.serve_step(transport, handlers, opts)
  end
end

return Rpc
