# Design: `lib/rpc.lua` — Reliable Request/Response over Rednet

**Date:** 2026-06-25
**Status:** Approved

---

## Context

CC rednet is fire-and-forget. `lib/rpc.lua` adds reliable request/response
semantics on top: correlation IDs, per-call timeout with retries, and pcall
isolation on the server side. The module is the communication backbone for
Cubernetes — the gateway calls nodes to scrape metrics and issue control
commands; nodes serve those requests.

Core constraints:
- No CC globals at module load time — injectable transport only
- Pure Lua, testable in vanilla Lua 5.3/5.4 at the unit level
- Pull model: gateway calls, nodes serve — not symmetric in practice

---

## Architecture

Two exported surfaces, cleanly separated:

**`Rpc` object — caller side**
Wraps a transport, owns a transaction controller internally. Stateful because
calling requires tracking in-flight correlation IDs.

**`Rpc.serve(transport, handlers, opts)` — server side**
Plain function, no shared state with the caller side. Loops on
`transport.receive()`, dispatches to handlers, sends responses.

```
┌─────────────────────────────────────────────────┐
│  caller coroutine          server coroutine      │
│                                                  │
│  rpc:call(target, method,  Rpc.serve(transport,  │
│    payload, opts)            handlers, opts)     │
│       │                          │               │
│  ┌────▼──────┐             ┌─────▼──────┐        │
│  │  txnctrl  │             │  dispatch  │        │
│  │ (id map)  │             │  + pcall   │        │
│  └────┬──────┘             └─────┬──────┘        │
│       │                          │               │
│  ┌────▼──────────────────────────▼──────┐        │
│  │           transport interface        │        │
│  │  send(target_id, msg)                │        │
│  │  receive(timeout_s) → id, msg        │        │
│  └──────────────────────────────────────┘        │
└─────────────────────────────────────────────────┘
```

---

## Transport Interface

The only seam between `rpc.lua` and the outside world. A plain table:

```lua
{
  send    = function(target_id, msg) end,
  receive = function(timeout_s) -> sender_id, msg end,
  -- returns nil, nil on timeout or empty inbox
}
```

`rpc.lua` never calls `rednet` directly. Three concrete implementations:

| Context | Implementation |
|---|---|
| Production | `Rpc.rednet_transport(side)` — thin factory wrapping `rednet.open/send/receive` |
| Unit tests | `fakes.make_loopback_pair()` — synchronous in-process pair |
| Integration tests | `Rpc.rednet_transport("top")` on a loopback rednet channel in CraftOS-PC |

---

## Message Envelope

```lua
--- @alias RpcMessageType
--- | 1  # REQUEST
--- | 2  # RESPONSE
--- | 3  # ERROR

--- @class RpcMessage
--- @field id      integer         correlation ID
--- @field type    RpcMessageType
--- @field method  string|nil      present on REQUEST only
--- @field payload any             args / return value / error string
```

`Rpc.TYPE` is a read-only constants table:

```lua
Rpc.TYPE = setmetatable({
  REQUEST  = 1,
  RESPONSE = 2,
  ERROR    = 3,
}, {
  __newindex = function() error("Rpc.TYPE is read-only") end,
  __index    = function(_, k) error("Rpc.TYPE." .. k .. " is undefined") end,
})
```

Integer values: faster equality comparison in the dispatch loop, more compact
over the wire (`textutils.serialize`).

---

## Transaction Controller (internal)

Owned by the `Rpc` object. Never exposed to callers.

```lua
_txns   = { [id] = { expiry = <absolute_time> } }
_next_id = 1  -- monotonically increasing
```

Internal operations:
- `_txn_create(timeout_s)` → stores expiry, returns new id
- `_txn_resolve(id)` → removes and returns entry, or nil if unknown/expired
- `_txn_cleanup()` → purges expired entries

---

## `call()` Behaviour

```lua
rpc:call(target_id, method, payload, opts)
-- opts defaults: { timeout = 5, attempts = 3 }
-- returns: ok, result  (ok=true on success, ok=false/nil on error or timeout)
```

Flow:

```
1. per_attempt_timeout = opts.timeout / opts.attempts
2. for attempt = 1 .. opts.attempts:
   a. id = _txn_create(per_attempt_timeout)
   b. transport.send(target_id, { id, TYPE.REQUEST, method, payload })
   c. poll loop until per_attempt_timeout expires:
      - sender, msg = transport.receive(remaining)
      - timeout          → break to retry (transport failure)
      - msg.id ~= id     → discard, keep polling (another call's response)
      - TYPE.RESPONSE    → _txn_resolve, return true, msg.payload
      - TYPE.ERROR       → _txn_resolve, return false, msg.payload  ← NO retry
3. return false, "timeout"
```

**Retry boundary:** transport timeout → retry. `TYPE.ERROR` response → no retry.
The node was reachable; the handler failed. Retrying won't fix it.

The poll loop discarding mismatched IDs is what makes concurrent calls safe —
each `call()` coroutine claims only its own response.

---

## `serve()` Behaviour

```lua
Rpc.serve(transport, handlers, opts)
-- opts: { on_error = function(method, err) end }  -- optional logging hook
-- handlers: { [method_name] = function(payload, sender_id) return value end }
-- blocks forever (run as a coroutine)
```

Flow:

```
loop forever:
  sender_id, msg = transport.receive()       -- no timeout
  if malformed or msg.type ~= TYPE.REQUEST → discard, continue
  handler = handlers[msg.method]
  if no handler → send TYPE.ERROR "unknown method: <msg.method>"
  ok, result = pcall(handler, msg.payload, sender_id)
  if ok     → send TYPE.RESPONSE { id=msg.id, payload=result }
  if not ok → send TYPE.ERROR    { id=msg.id, payload=result }
              call opts.on_error(msg.method, result) if provided
```

Handler signature:
```lua
handlers = {
  get_metrics = function(payload, sender_id) return { ... } end,
}
```

`sender_id` is always passed — most handlers ignore it, but it's available for
handlers that need to call back to the requesting node.

---

## Error Handling Summary

| Situation | Behaviour |
|---|---|
| Handler throws | `pcall` catches → `TYPE.ERROR` response → serve loop continues |
| Unknown method | `TYPE.ERROR` response: `"unknown method: <name>"` |
| Transport timeout (caller) | Retry up to `opts.attempts` times |
| `TYPE.ERROR` received (caller) | Return `false, err` immediately — no retry |
| All attempts exhausted | Return `false, "timeout"` |
| Malformed message received (server) | Discard silently, continue loop |

---

## Testing

### Unit tests — `test/rpc_test.lua` (vanilla Lua)

Add `fakes.make_loopback_pair()` to `test/support/fakes.lua`:

```lua
function M.make_loopback_pair()
  local inbox_a, inbox_b = {}, {}
  local function make(my_inbox, their_inbox)
    return {
      send    = function(_, msg) table.insert(their_inbox, msg) end,
      receive = function(_) return table.remove(my_inbox, 1) end,
    }
  end
  return make(inbox_a, inbox_b), make(inbox_b, inbox_a)
end
```

Covers:
- Envelope construction and field validation
- Correlation ID matching; mismatched IDs discarded
- `TYPE.ERROR` → no retry, immediate error return
- Transport timeout → retry up to max attempts
- `serve()` dispatch, pcall isolation, error response shaping
- Unknown method → error response
- `Rpc.TYPE` read-only and undefined-key guards

### Integration tests — `test/cc/rpc_integration_test.lua` (CraftOS-PC)

Two coroutines in `parallel.waitForAll` over a real loopback rednet channel.

Covers:
- Real `os.pullEvent` yield/resume cycle
- Concurrent calls in flight simultaneously
- Actual timeout behaviour under CC scheduling

---

## File Locations

| File | Action |
|---|---|
| `lib/rpc.lua` | Create |
| `test/rpc_test.lua` | Create |
| `test/cc/rpc_integration_test.lua` | Create (CraftOS-PC, runs in CI only) |
| `test/support/fakes.lua` | Extend — add `make_loopback_pair()` |
