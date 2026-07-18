# Mineplane — Current Status

_Last updated: 2026-07-05_

## Summary

Foundation is complete. All four originally-planned foundation modules are
shipped and tested. The Cubernetes orchestration layer (node registration,
heartbeat, scraping, flushing) is also substantially built. The scheduler,
alert engine, reconciler, and dashboard are next.

---

## What's Built

### lib/ — pure Lua utilities

| Module | Purpose | Tests |
|---|---|---|
| `lib/ring_buffer.lua` | Fixed-size circular buffer; hot layer for TSDB | 23 |
| `lib/tsdb.lua` | Unified hot+cold TSDB for a single metric series | 12 |
| `lib/cold_store.lua` | Disk-backed cold storage; two-tier CSV with downsampling | 16 |
| `lib/rpc.lua` | Reliable request/response over rednet; correlation IDs, retry, pcall isolation | 35 |
| `lib/registry.lua` | Pure node registry; liveness tracking, health state machine | 18 |
| `lib/display.lua` | CC monitor rendering helpers | 8 |

### core/ — Cubernetes + Paneltorch controllers

| Module | Purpose | Tests |
|---|---|---|
| `core/metrics.lua` | Prometheus-style multi-series registry; OLS rate(), sum_latest() | 47 |
| `core/scrape_controller.lua` | Pull-based collector scraper; runs as coroutine | 29 |
| `core/flush_controller.lua` | Periodic TSDB hot→cold flusher; runs as coroutine | 10 |
| `core/node_agent.lua` | Worker-side registration + heartbeat agent | 12 |
| `core/node_display.lua` | Registry monitor renderer; runs as coroutine | 12 |
| `core/registry_server.lua` | Controlplane-side REGISTER/HEARTBEAT dispatcher | 6 |

**Total: 234 tests, 0 failing.**

### computers/ — deployment entrypoints

Bootstrap, startup, probe, and example collector/config files for real
CC computers. Not unit-tested (CC globals).

### test/support/

- `fakes.lua` — injectable fakes: `make_loopback_pair()`, mock clocks,
  mock transports, mock filesystems
- `assert_lib.lua` — custom assertions: `assert.equals`, `assert.same`,
  `assert.near`, `assert.error_matches`, etc.

---

## What's Missing (spec build order)

| # | Item | Notes |
|---|---|---|
| 8 | `core/scheduler.lua` | Pull-based scrape scheduler; per-collector intervals; `tcd` timer dispatcher pattern from cc-mek-scada |
| 9 | First real collector end-to-end | Energy detector → metric store → dashboard |
| 10 | `core/alerts.lua` | Rule engine; cooldowns; severity routing |
| 11 | `core/reconciler.lua` | First real controller — spawner stock keeper |
| 12 | Dashboard rendering | `term.blit`, Pixelbox Lite, widget surface abstraction |
| 13 | Enderlink | External broker + web/phone UI + push notifications |

**Deferred (explicitly):**

- `mocks/world.lua` — tickable ATM10 base simulator with realistic peripheral
  APIs. Deferred until the Paneltorch/Cubernetes stack is stable enough that
  integration testing becomes the bottleneck. Building it now would be
  premature — there are no controllers yet to drive through it.

---

## Architecture Invariants (don't break these)

- No CC globals at module load time — every module must be loadable in vanilla
  Lua 5.3/5.4. CC APIs injected via parameters or a `ctx` object.
- Never call `peripheral.wrap()` directly — always through a mockable boundary.
- Pull model: scrape-don't-push everywhere.
- `parallel.waitForAll` + `os.pullEvent()` for concurrency — each controller
  runs as a self-restarting coroutine with backoff (`p_exec` pattern).
- Tests run with `lua test/runner.lua` — no external framework.

---

## Next Up

`core/scheduler.lua` — the pull-based scrape scheduler. Responsible for
dispatching collector scrapes on configurable per-collector intervals using
the `tcd` (timer callback dispatcher) pattern. This is the piece that
connects `scrape_controller.lua` (which does one scrape step) to real
wall-clock time and multi-collector scheduling.
