-- Copy this file to collectors.lua on a worker computer.
-- Return a list of collector specs. Each spec is registered with
-- the ScrapeController on boot. The `collect` function runs every
-- scrape_interval seconds and must return a number or nil.
--
-- Collectors here are examples — delete what you don't need and
-- adjust peripheral names to match your setup.

return {

  -- ── Mekanism energy cell ───────────────────────────────────────────────────
  -- Wraps the first energy cell peripheral found on any side.
  -- Returns stored energy in Forge Energy (FE) units.
  --
  -- {
  --   name    = "energy_stored",
  --   collect = function(_, _)
  --     local cell = peripheral.find("mekanismEnergyCell")
  --     if not cell then return nil end
  --     return cell.getEnergy()
  --   end,
  -- },

  -- ── Create: mechanical bearing / stress ────────────────────────────────────
  -- {
  --   name    = "stress_capacity",
  --   collect = function(_, _)
  --     local bearing = peripheral.wrap("front")
  --     if not bearing then return nil end
  --     return bearing.getStressCapacity()
  --   end,
  -- },

  -- ── Turtle fuel level ──────────────────────────────────────────────────────
  -- Only meaningful if this computer is a turtle.
  --
  -- {
  --   name    = "fuel_level",
  --   collect = function(_, _)
  --     return turtle and turtle.getFuelLevel() or nil
  --   end,
  -- },

}
