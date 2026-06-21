# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run all tests
lua test/runner.lua

# Run a single test file
lua test/runner.lua test/ring_buffer_test.lua

# Format Lua files (requires stylua)
stylua .

# Pull CC:Tweaked LuaCATS stubs (run once after cloning)
bash scripts/setup-types.sh
```

## Architecture

Mineplane is a Lua codebase that runs inside **CC:Tweaked** (a Minecraft Lua
VM). Three layers, each with its own directory once built out:

- **Cubernetes** (`core/`) — orchestration: distributed node registry,
  heartbeat, pull-based scrape scheduling, declarative reconciliation
  controllers (Kubernetes operator pattern).
- **Paneltorch** (also `core/`) — observability: in-game TSDB with a ring
  buffer hot layer, disk cold layer with tiered downsampling, unified query
  API, optional Prometheus/Grafana export.
- **Enderlink** (`enderlink/`) — edge/ingress: external broker bridging
  non-publicly-reachable CC computers via HTTPS polling to a Vercel/Fly host.

Supporting directories:

- `lib/` — pure-Lua utilities with no CC globals (testable in vanilla Lua).
- `mocks/` — injectable fakes for `peripheral`, `os`, etc.
- `test/` — busted-style test files plus the standalone test runner.
- `.luals/cc-tweaked/` — LuaCATS type stubs (gitignored, populated by
  `scripts/setup-types.sh`).

## Key design rules

1. **No CC globals at module load time.** Every module must be loadable and
   testable in plain lua5.3/5.4. CC APIs (`peripheral`, `rednet`, `os`, etc.)
   are injected via parameters or a `ctx` context object, never called directly
   at the top level.
2. **Never call `peripheral.wrap()` directly.** Always use the mockable
   boundary so tests can substitute fakes.
3. **Pull model throughout.** Scrape-don't-push (Prometheus style); desired
   state + reconciliation loops, not imperative if/then.
4. **Everything is a plugin.** Collector, Rule, Widget, and Controller are
   contracts; `ctx` is the stable versioned API they program against.
5. **Concurrency via `parallel.waitForAll` + `os.pullEvent()`.** CC is
   single-threaded; cooperative coroutines share a single event loop. Threads
   use a self-restarting `p_exec` pattern with backoff.

## Test runner DSL

Test files use globals injected by `test/runner.lua` — no `require` needed:

```lua
describe("Suite name", function()
  it("does something", function()
    assert.equals(actual, expected)
    assert.same(actual, expected)   -- deep equality
    assert.near(actual, expected, epsilon)
    assert.truthy(value)
    assert.falsy(value)
    assert.is_nil(value)
    assert.error_matches(fn, pattern)
  end)
end)
```

Tests can `require("lib.foo")` normally because the runner runs from the repo
root and Lua's package path resolves from `.`.

## Formatting

StyLua config (`stylua.toml`): 100-column width, 2-space indent, double quotes.
