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

return Rpc
