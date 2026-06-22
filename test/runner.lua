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

local assert_lib = require("test.support.assert_lib")

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
  local handle = io.popen("find test -maxdepth 1 -name '*_test.lua' 2>/dev/null")
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
