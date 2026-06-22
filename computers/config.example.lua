-- Copy this file to config.lua on each computer and fill in the values.
-- The startup script reads config.lua automatically on boot.

return {
  -- "master" runs the registry server.
  -- "worker" registers with the master and sends heartbeats.
  role = "worker",

  -- Human-readable name for this computer. Falls back to os.getComputerLabel()
  -- if not set. Set it with the in-game `label set <name>` command instead if
  -- you prefer to keep config.lua identical across all workers.
  label = nil,

  -- Arbitrary key/value tags visible in the registry (zone, type, etc.).
  labels = {
    -- type = "turtle",
    -- zone = "overworld",
  },

  -- How often the worker sends heartbeats, in seconds.
  -- Must be less than the master's timeout_seconds (default 45).
  heartbeat_interval = 15,

  -- Master-only: how long before a node is marked NotReady (seconds).
  timeout_seconds = 45,

  -- Master-only: how long before a NotReady node is evicted (seconds).
  eviction_seconds = 300,
}
