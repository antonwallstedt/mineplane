-- CC:Tweaked-compatible test runner for CraftOS-PC headless mode.
-- Runs the same *_test.lua files as test/runner.lua but using CC APIs
-- (fs.list for discovery, os.shutdown for exit codes) instead of io.popen
-- and os.exit.
--
-- Usage: see scripts/test-cc.sh — do not invoke directly.
--
-- Output is written to /results.txt in the CC computer's own filesystem.
-- The shell wrapper reads and prints that file after craftos exits, giving
-- clean line-by-line output. Avoiding print()/io.write() during the run
-- prevents the headless renderer from dumping 19 padded terminal rows on
-- every character, which would produce hundreds of KB of noise.

local PROJECT = "/project"
local RESULTS_FILE = "/results.txt"

-- Wire project modules into the CC require path so require("lib.foo") works.
package.path = PROJECT .. "/?.lua;" .. PROJECT .. "/?/init.lua;" .. (package.path or "")

local assert_lib = require("test.support.assert_lib")

-- ── output buffer ──────────────────────────────────────────────────────────

local output = {}

local function out(s)
  table.insert(output, tostring(s))
end

local function flush_output()
  local f = fs.open(RESULTS_FILE, "w")
  for _, line in ipairs(output) do
    f.writeLine(line)
  end
  f.close()
end

-- ── state ──────────────────────────────────────────────────────────────────

local state = {
  suite_name = nil,
  passed     = 0,
  failed     = 0,
  errors     = {},
}

-- ── DSL ────────────────────────────────────────────────────────────────────

local function describe(suite_name, fn)
  local prev = state.suite_name
  state.suite_name = suite_name
  fn()
  state.suite_name = prev
end

local function it(test_name, fn)
  local suite = state.suite_name or "(top)"
  local ok, err = pcall(fn)
  if ok then
    state.passed = state.passed + 1
    out("  [P] " .. test_name)
  else
    state.failed = state.failed + 1
    table.insert(state.errors, { suite = suite, name = test_name, msg = err })
    out("  [F] " .. test_name)
    out("      " .. tostring(err))
  end
end

-- ── discovery ──────────────────────────────────────────────────────────────

local function collect_tests(dir, results)
  results = results or {}
  for _, name in ipairs(fs.list(dir)) do
    local path = dir .. "/" .. name
    if fs.isDir(path) then
      collect_tests(path, results)
    elseif name:match("_test%.lua$") then
      table.insert(results, path)
    end
  end
  table.sort(results)
  return results
end

-- ── runner ─────────────────────────────────────────────────────────────────

local function run_file(path)
  _G.describe = describe
  _G.it       = it
  _G.assert   = assert_lib

  -- Pass _ENV explicitly so the chunk inherits CC's sandboxed environment
  -- (require, fs, os, etc.) rather than the raw _G where they're absent.
  local chunk, err = loadfile(path, "t", _ENV)
  if not chunk then
    out("")
    out("ERROR loading " .. path .. ": " .. tostring(err))
    state.failed = state.failed + 1
    return
  end

  out("")
  out(path)
  local ok, load_err = pcall(chunk)
  if not ok then
    out("  ERROR: " .. tostring(load_err))
    state.failed = state.failed + 1
  end
end

-- ── main ───────────────────────────────────────────────────────────────────

local files = collect_tests(PROJECT .. "/test")
if #files == 0 then
  out("No test files found under " .. PROJECT .. "/test")
  flush_output()
  os.shutdown(0)
end

for _, f in ipairs(files) do
  run_file(f)
end

-- ── summary ────────────────────────────────────────────────────────────────

out(string.rep("-", 60))

if #state.errors > 0 then
  out("")
  out("FAILURES:")
  out("")
  for _, e in ipairs(state.errors) do
    out(string.format("  %s > %s", e.suite, e.name))
    out("    " .. tostring(e.msg))
    out("")
  end
end

out(string.format("\n%d passed, %d failed", state.passed, state.failed))

flush_output()
os.shutdown(state.failed > 0 and 1 or 0)
