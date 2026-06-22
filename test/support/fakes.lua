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
        writeLine = function(line)
          store[path] = store[path] .. line .. "\n"
        end,
        close = function() end,
      }
    end,
    _store = store,
  }
end

function M.make_transport()
  local sent, broadcasts, inbox = {}, {}, {}
  return {
    send      = function(id, msg) table.insert(sent, { to = id, msg = msg }) end,
    broadcast = function(msg)     table.insert(broadcasts, msg) end,
    receive   = function(_)
      local item = table.remove(inbox, 1)
      if item then return item.from, item.msg end
    end,
    _sent       = sent,
    _broadcasts = broadcasts,
    inject      = function(from, msg) table.insert(inbox, { from = from, msg = msg }) end,
  }
end

function M.make_ctx(epoch_ms, sleep_fn)
  return {
    os = {
      epoch = function(_) return epoch_ms end,
      sleep = sleep_fn or function() end,
    },
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
