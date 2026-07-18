# Mineplane — Project Brief

A cloud-native monitoring and automation platform for modded Minecraft, built on
ComputerCraft: Tweaked + Advanced Peripherals, targeting ATM10. Think Prometheus +
Kubernetes, running natively inside a Minecraft base. Real open-source project:
IDE-based development, mocked test harness, CI, plugin ecosystem.

**Important: this is a learning project.** I want to write the implementation
myself. Claude Code's role is collaborator and reviewer, not author — pair-program,
explain tradeoffs, point out bugs and better patterns, write small illustrative
snippets when useful, but let me drive the actual implementation of core logic.
Lean toward asking clarifying/design questions and reviewing my code over
generating whole files unprompted. It's fine to scaffold boilerplate (file
structure, test runner shell, repetitive config) since that's not where the
learning is.

---

## The Stack

Three named layers:

- **Cubernetes** (orchestration) — distributed node registry, service discovery,
  heartbeat/health tracking, pull-based scrape scheduling, declarative
  reconciliation controllers (Kubernetes operator pattern)
- **Paneltorch** (observability) — in-game time-series database. Ring buffer hot
  layer (last ~5 min, fast `rate()`/`avg()`), TSDB disk layer with tiered
  downsampling and configurable retention (e.g. 1-min averages kept 1 day, 1-hour
  averages kept 7 days, auto-compaction), unified query API with transparent
  hot/warm fallback. Optional export to real Prometheus/Grafana.
- **Enderlink** (edge/ingress) — external broker (Vercel/Fly) bridging the fact
  that CC computers aren't publicly reachable. In-game server polls broker over
  HTTPS (pull commands down, push state up). Enables web/phone monitoring and
  control, push notifications on critical alerts.

---

## Core Design Principles

1. Pull model everywhere (server scrapes nodes on its own schedule —
   Prometheus-style, not push)
2. Everything is a plugin — four contracts: **Collector** (monitor), **Rule**
   (alert/automate on condition), **Widget** (visualize), **Controller**
   (reconcile toward desired state)
3. `ctx` object is the stable, versioned public API every plugin talks through
   (`peripherals`, `metrics`, `log`, `emit_event`, `config`, `schedule`)
4. New input sources (chat command, web command, internal trigger) collapse into
   the same event bus — never parallel paths
5. Declarative desired state + reconciliation loops (not one-shot if/then) —
   controllers continuously observe and act to close the gap between actual and
   desired state
6. Never call `peripheral.wrap()` directly — always through a mockable boundary,
   enabling full testing without Minecraft

---

## Reconciliation Model (the "Kubernetes" part)

Controllers run a continuous loop: observe current state via `ctx.metrics`,
compare to declared desired state (config, not code), act via `ctx.actuators` to
close the gap, repeat forever (every ~5s). Self-healing by construction — a server
restart just re-observes and corrects drift. Goes beyond k8s by using the
historian's `rate()` for *predictive* action (e.g. spin up backup power before
stored energy hits zero, not after). Each controller's reconcile call is
`pcall`-wrapped so one buggy controller can't crash the reconciler.

---

## Concurrency Model

CC is single-threaded; concurrency is `parallel.waitForAll` running coroutines
that cooperate via `os.pullEvent()` yields. Server runs scrape scheduler, RPC
server, alert engine, reconciler, and dashboard renderer as parallel coroutines
sharing a `__smem` state table. Each thread self-restarts on crash with backoff
(the `p_exec` pattern from cc-mek-scada).

---

## Foundation Modules

These four modules were prototyped once already and discarded intentionally so
the author can build them and actually learn the material. Treat this section as
the spec for what they need to do.

### `lib/ring_buffer.lua`

Fixed-size circular buffer for time-series samples. Bounded memory: oldest sample
overwritten when full. Must support:

- `push(t, v)`
- `count()`, `capacity()`, `is_empty()`
- `latest()`, `oldest()`
- `last(n)` — returning oldest-first logical order regardless of physical wrap
  position
- `all()`, `iter()`, `clear()`

The hard part worth getting right through review: translating a logical index
(1=oldest) to a physical buffer index correctly across both the pre-wrap and
post-wrap cases. Want Claude Code to push for testing the heavy-overflow case
specifically (many pushes through a small buffer) since that's where wrap-around
bugs hide.

### `core/metrics.lua`

Prometheus-style data model on top of ring buffers. A metric is identified by
name + labels (e.g. `energy.flow{segment="mekanism"}`); each unique (name,
labels) pair is a distinct series. Needs:

- `record(name, value, labels, t)`
- `latest()`, `range(n)`, `avg(n)`, `max(n)`, `min(n)`
- `rate(n)` — per-second linear rate over the window; this is what powers
  flatline prediction; want to get the math right
- `sum_latest()` — aggregate across all series matching a label subset
- `series_labels()`, `metric_names()`

Series identity must be stable regardless of label key insertion order. Clock
should be injectable (defaults to wall time) so a future mock world can
fast-forward time during tests.

### `mocks/world.lua`

A tickable simulation of an ATM10 base with real dynamics: power
generation/storage/segmented draw, spawners (cost power, produce drops when
enabled), farms (produce items, toggleable), an in-memory item/ME storage table.
Exposes peripheral-shaped objects matching real Advanced Peripherals method
signatures:

- Energy Detector: `getTransferRate()`, `setTransferRateLimit()`
- ME Bridge: `isOnline()`, `listItems()`, `getItem(filter)`, `craftItem(filter)`,
  `getCraftingJobs()`

`tick(dt)` advances simulated time and applies all dynamics proportionally to dt.
Goal: a controller test should be able to drain stock, watch a reconciler turn on
a spawner, and watch stock recover — all in simulated time only. Want to think
through what "realistic enough to catch real bugs" looks like without
over-engineering it.

### `lib/rpc.lua`

Reliable request/response over rednet (which is otherwise fire-and-forget).
Message envelope with correlation IDs, request/response/event types.

- `call(target_id, method, payload, opts)` — blocks until response or timeout,
  with configurable retries. Key distinction: retry on transport timeout (node
  unreachable) but NOT on a valid error response (node reachable, handler failed —
  retrying won't fix it).
- `serve(handlers, opts)` — dispatch loop on the receiving side, pcall-wrapping
  handlers so a crashing handler becomes an error response instead of killing the
  node.

Injectable transport so the whole thing is testable via an in-process loopback
pair instead of real rednet. Getting a deterministic test harness for inherently
async request/response is the trickiest design problem here.

---

## Build Order After Foundation

5. `core/tsdb.lua` — disk persistence, tiered retention/downsampling, range
   queries (pure Lua, testable like the above)
6. `core/server.lua` — `parallel.waitForAll` skeleton, shared state, event
   dispatch loop
7. `core/registry.lua` — node registration handshake, heartbeat watchdog, health
   state machine (Pending/Ready/NotReady/Gone)
8. `core/scheduler.lua` — pull-based scrape scheduler, per-collector configurable
   intervals, timer callback dispatcher (`tcd` pattern)
9. First real collector end-to-end (energy detector → metric store → dashboard)
10. `core/alerts.lua` — rule engine with cooldowns, severity routing
11. `core/reconciler.lua` — first real controller (spawner stock keeper)
12. Dashboard rendering — `term.blit`, Pixelbox Lite integration for 6×
    subcharacter resolution, widget surface abstraction
13. Enderlink broker + web/phone UI + push notifications

---

## Prior Art

- **cc-mek-scada** — borrow: coroutine thread model, `tcd` timer dispatcher,
  `ppm` protected-peripheral pcall wrapper, `adaptive_delay` clock, `p_exec`
  self-restart, channel-per-role networking, HMAC auth (`lockbox` lib). Avoid:
  hardcoded topology, push model, no historian, no plugin system, zero mocks.
- **Telem** — use its adapter source purely as ground-truth documentation for
  AP/Mekanism peripheral method signatures. Do not depend on it: no persistence,
  no distribution, no automation, zero tests.
- **Basalt2** — candidate for dashboard *client* computers only (not the server)
  for retained-mode UI components, decide later.
- **Pixelbox Lite** — vendor directly later (single file, no architectural
  opinions), teletext subcharacter rendering (2×3 pixels per character cell via
  `term.blit`).
- **CryptoNet** — reference only, for pure-Lua crypto if encryption beyond HMAC
  auth is ever needed.

---

## Repo Structure (target)

```
/os/         startup.lua
/core/       metrics.lua, tsdb.lua, registry.lua, scheduler.lua, alerts.lua,
             reconciler.lua, rednet_server.lua, events.lua
/plugins/    collectors/ rules/ widgets/ controllers/ exporters/
/dashboard/  server.lua, widgets/ (graph, gauge, table, alert_banner)
/clients/    energy_panel.lua, stock_panel.lua, chat_cli.lua
/lib/        ring_buffer.lua, rpc.lua, pretty.lua, config.lua
/mocks/      world.lua, energy_detector.lua, me_bridge.lua, ...
/specs/      peripheral contract specs (energy_detector.lua, me_bridge.lua, ...)
/ci/         peripheral_spy.lua, verify_collectors.lua
/test/       unit tests
/examples/   power-monitoring/, farm-automation/, full-base/
/enderlink/  broker (external service) + web UI
```

---

## CI/CD Pipeline (designed, build after foundation modules exist)

1. GitHub Actions: run full Lua test suite on every push/PR
2. Selene linting with CC type stubs
3. **Peripheral contract verification** — hand-written spec files per peripheral
   type; a spying mock validates every collector's peripheral calls against the
   spec via `__index` metamethod trapping; catches typos and wrong assumptions in
   CI, before ever touching Minecraft
4. `startup.lua` GitHub-raw-file puller for deploy (manifest-based, only
   updates/reboots affected nodes)
5. Enderlink webhook triggers in-game deploy on push
6. Canary deploys — push to one node first, watch health via Enderlink,
   auto-rollback on failure, then roll out fleet-wide
7. CraftOS-PC headless integration tests in CI (real `parallel.waitForAll` /
   `rednet` / `os.pullEvent`, no Minecraft required)
8. PR preview environments — temporary CraftOS-PC instance per PR, exposed via
   Enderlink, torn down on merge

---

## Naming

Mineplane (umbrella) — Cubernetes (orchestration), Paneltorch (observability),
Enderlink (edge/ingress).
