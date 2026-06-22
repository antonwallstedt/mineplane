local M = {}

function M.make_fs()
  local store = {}
  return {
    exists = function(path)
      return store[path] ~= nil
    end,
    open = function(path, mode)
      if mode == "w" then
        store[path] = ""
      elseif mode == "a" then
        store[path] = store[path] or ""
      end
      local buf = store[path] or ""
      local lines = {}
      for line in (buf .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
          table.insert(lines, line)
        end
      end
      local read_pos = 1
      return {
        readLine = function()
          local line = lines[read_pos]
          read_pos = read_pos + 1
          return line
        end,
        writeLine = function(_, line)
          store[path] = store[path] .. line .. "\n"
        end,
        close = function() end,
      }
    end,
    _store = store,
  }
end

function M.average(...)
  local values = { ... }
  local sum = 0
  for _, v in ipairs(values) do
    sum = sum + v
  end
  return sum / #values
end

return M
