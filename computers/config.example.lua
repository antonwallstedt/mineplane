-- Copy this file to config.lua on each computer and fill in the values.
-- The startup script reads config.lua automatically on boot.

return {
  -- "controlplane" runs the registry server.
  -- "worker" registers with the controlplane and sends heartbeats.
  role = "worker",

  -- Human-readable name for this computer. Falls back to os.getComputerLabel()
  -- if not set. Set it with the in-game `label set <name>` command instead if
  -- you prefer to keep config.lua identical across all workers.
  label = nil,

  -- Worker-only (required): named area/location this computer belongs to.
  node = "factory",

  -- Arbitrary key/value tags visible in the registry (zone, type, etc.).
  labels = {
    -- type = "turtle",
    -- zone = "overworld",
  },

  -- How often the worker sends heartbeats, in seconds.
  -- Must be less than the controlplane's timeout_seconds (default 45).
  heartbeat_interval = 15,

  -- Controlplane-only: how long before a node is marked NotReady (seconds).
  timeout_seconds = 45,

  -- Controlplane-only: how long before a NotReady node is evicted (seconds).
  eviction_seconds = 300,

  -- Where to store metric data on this computer's filesystem.
  metrics_path = "/mineplane/metrics",

  -- How often to scrape collectors, in seconds.
  scrape_interval = 15,

  -- How often to flush the in-memory ring buffer to disk, in seconds.
  flush_interval = 60,

  -- How often to redraw the monitor display, in seconds.
  refresh_seconds = 5,
}
