--- Shared busted-style assert helpers.
--- Works in plain Lua 5.3/5.4 and in CC:Tweaked (CraftOS-PC).
--- Required by both test/runner.lua and test/cc_runner.lua.

local M = setmetatable({}, {
  __call = function(_, value, message)
    if not value then
      error(message or "assertion failed!", 2)
    end
  end,
})

function M.equals(actual, expected, msg)
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

function M.not_equals(actual, expected, msg)
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

function M.truthy(value, msg)
  if not value then
    error(
      string.format("%s\n  expected truthy, got: %s", msg or "truthy failed", tostring(value)),
      2
    )
  end
end

function M.falsy(value, msg)
  if value then
    error(string.format("%s\n  expected falsy, got: %s", msg or "falsy failed", tostring(value)), 2)
  end
end

function M.near(actual, expected, epsilon, msg)
  epsilon = epsilon or 1e-9
  if math.abs(actual - expected) > epsilon then
    error(
      string.format(
        "%s\n  expected ~%s (+/-%s), got %s",
        msg or "near failed",
        tostring(expected),
        tostring(epsilon),
        tostring(actual)
      ),
      2
    )
  end
end

function M.is_nil(value, msg)
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

function M.same(actual, expected, msg)
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

function M.error_matches(fn, pattern, msg)
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

return M
