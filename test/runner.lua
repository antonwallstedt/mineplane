-- Minimal busted-style test runner for plain lua5.3/lua5.4.
-- Usage: lua test/runner.lua [test/file1.lua ...]
-- With no args, discovers all test/*.lua files except itself.

local runner = {}

-- ── state ──────────────────────────────────────────────────────────────────

local _state = {
  suite_name = nil,
  passed = 0,
  failed = 0,
  errors = {}, -- { suite, name, msg }
}

-- ── assert helpers ─────────────────────────────────────────────────────────

local assert_lib = setmetatable({}, {
  -- allow assert(value, msg) to work like the built-in inside production modules
  __call = function(_, value, message)
    if not value then
      error(message or "assertion failed!", 2)
    end
  end,
})

function assert_lib.equals(actual, expected, msg)
  if actual ~= expected then
    error(
      string.format(
        "%s\n  expected: %s\n    actual: %s",
        msg or "equals failed",
        tostring(expected),
        tostring(actual)
      ),
      2
    )
  end
end

function assert_lib.not_equals(actual, expected, msg)
  if actual == expected then
    error(
      string.format(
        "%s\n  expected values to differ, both: %s",
        msg or "not_equals failed",
        tostring(actual)
      ),
      2
    )
  end
end

function assert_lib.truthy(value, msg)
  if not value then
    error(
      string.format("%s\n  expected truthy, got: %s", msg or "truthy failed", tostring(value)),
      2
    )
  end
end

function assert_lib.falsy(value, msg)
  if value then
    error(string.format("%s\n  expected falsy, got: %s", msg or "falsy failed", tostring(value)), 2)
  end
end

function assert_lib.near(actual, expected, epsilon, msg)
  epsilon = epsilon or 1e-9
  if math.abs(actual - expected) > epsilon then
    error(
      string.format(
        "%s\n  expected ~%s (±%s), got %s",
        msg or "near failed",
        tostring(expected),
        tostring(epsilon),
        tostring(actual)
      ),
      2
    )
  end
end

function assert_lib.is_nil(value, msg)
  if value ~= nil then
    error(string.format("%s\n  expected nil, got: %s", msg or "is_nil failed", tostring(value)), 2)
  end
end

local function serialize(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local parts = {}
  for k, v in pairs(value) do
    table.insert(parts, tostring(k) .. "=" .. serialize(v))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equals(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not deep_equals(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

function assert_lib.same(actual, expected, msg)
  if not deep_equals(actual, expected) then
    error(
      string.format(
        "%s\n  expected: %s\n    actual: %s",
        msg or "same failed",
        serialize(expected),
        serialize(actual)
      ),
      2
    )
  end
end

function assert_lib.error_matches(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    error(string.format("%s\n  no error was raised", msg or "error_matches failed"), 2)
  end
  if not tostring(err):match(pattern) then
    error(
      string.format(
        "%s\n  error %q did not match pattern %q",
        msg or "error_matches failed",
        tostring(err),
        pattern
      ),
      2
    )
  end
end

-- ── DSL ────────────────────────────────────────────────────────────────────

function runner.describe(suite_name, fn)
  local prev = _state.suite_name
  _state.suite_name = suite_name
  fn()
  _state.suite_name = prev
end

function runner.it(test_name, fn)
  local suite = _state.suite_name or "(top)"
  local label = suite .. " > " .. test_name
  local ok, err = pcall(fn)
  if ok then
    _state.passed = _state.passed + 1
    io.write("  ✓ " .. test_name .. "\n")
  else
    _state.failed = _state.failed + 1
    table.insert(_state.errors, { suite = suite, name = test_name, msg = err })
    io.write("  ✗ " .. test_name .. "\n")
  end
end

-- ── file discovery ─────────────────────────────────────────────────────────

local function discover_tests()
  local files = {}
  -- popen is available in standard Lua but not CC; fine for CI/dev
  local handle = io.popen("find test -name '*.lua' -not -name 'runner.lua' 2>/dev/null")
  if handle then
    for line in handle:lines() do
      table.insert(files, line)
    end
    handle:close()
  end
  table.sort(files)
  return files
end

-- ── main ───────────────────────────────────────────────────────────────────

local function run_file(path)
  -- Expose DSL into the test file's environment via globals.
  -- Test files do:  local describe, it, assert = describe, it, assert
  _G.describe = runner.describe
  _G.it = runner.it
  _G.assert = assert_lib -- shadow the built-in (we never use it raw)

  local chunk, err = loadfile(path)
  if not chunk then
    io.write("\nERROR loading " .. path .. ": " .. tostring(err) .. "\n")
    _state.failed = _state.failed + 1
    return
  end

  io.write("\n" .. path .. "\n")
  local ok, load_err = pcall(chunk)
  if not ok then
    io.write("  ERROR: " .. tostring(load_err) .. "\n")
    _state.failed = _state.failed + 1
  end
end

local files = {}
if #arg > 0 then
  files = arg
else
  files = discover_tests()
end

if #files == 0 then
  io.write("No test files found.\n")
  os.exit(0)
end

for _, f in ipairs(files) do
  run_file(f)
end

-- ── summary ────────────────────────────────────────────────────────────────

io.write(string.rep("─", 60) .. "\n")

if #_state.errors > 0 then
  io.write("\nFAILURES:\n\n")
  for _, e in ipairs(_state.errors) do
    io.write(string.format("  %s > %s\n    %s\n\n", e.suite, e.name, tostring(e.msg)))
  end
end

io.write(string.format("\n%d passed, %d failed\n", _state.passed, _state.failed))

os.exit(_state.failed > 0 and 1 or 0)
