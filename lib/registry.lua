--- Pure node registry: tracks worker computers, their liveness, and metadata.
--- No CC globals, no transport. Testable in vanilla Lua.
---
--- Node status lifecycle:
---   register → Ready
---   tick, age > timeout_seconds → NotReady
---   tick, age > eviction_seconds → removed

local Registry = {}
Registry.__index = Registry

local DEFAULTS = {
  timeout_seconds  = 45,
  eviction_seconds = 300,
}

--- @param config table  { timeout_seconds?, eviction_seconds? }
--- @return Registry
function Registry.new(config)
  config = config or {}
  local self = setmetatable({}, Registry)
  self._timeout  = config.timeout_seconds  or DEFAULTS.timeout_seconds
  self._eviction = config.eviction_seconds or DEFAULTS.eviction_seconds
  self._nodes    = {}
  return self
end

--- Upsert a node. Always sets last_seen = now and status = "Ready".
--- @param node_info table  { id, label?, labels? }
--- @param now       number  epoch seconds
function Registry:register(node_info, now)
  assert(type(node_info.id) == "number", "node_info.id must be a number")
  assert(type(now) == "number", "now must be a number")
  local existing = self._nodes[node_info.id] or {}
  self._nodes[node_info.id] = {
    id            = node_info.id,
    label         = node_info.label  or existing.label  or "",
    labels        = node_info.labels or existing.labels or {},
    last_seen     = now,
    registered_at = existing.registered_at or now,
    status        = "Ready",
  }
end

--- Update last_seen for a known node. No-op for unknown id.
--- @param id  number
--- @param now number  epoch seconds
function Registry:heartbeat(id, now)
  local node = self._nodes[id]
  if node then
    node.last_seen = now
  end
end

--- Advance liveness: mark stale nodes NotReady, evict expired ones.
--- @param now number  epoch seconds
function Registry:tick(now)
  for id, node in pairs(self._nodes) do
    local age = now - node.last_seen
    if age > self._eviction then
      self._nodes[id] = nil
    elseif age > self._timeout then
      node.status = "NotReady"
    end
  end
end

--- All registered nodes, sorted ascending by id.
--- @return table[]
function Registry:nodes()
  local result = {}
  for _, node in pairs(self._nodes) do
    table.insert(result, node)
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

--- Nodes whose status is "Ready".
--- @return table[]
function Registry:ready_nodes()
  local result = {}
  for _, node in ipairs(self:nodes()) do
    if node.status == "Ready" then
      table.insert(result, node)
    end
  end
  return result
end

--- Single node record by id, or nil.
--- @param id number
--- @return table|nil
function Registry:get(id)
  return self._nodes[id]
end

return Registry
