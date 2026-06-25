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

function M.make_monitor()
  local cleared = 0
  local scale_set = nil
  local written = {}
  return {
    clear        = function()    cleared = cleared + 1; written = {} end,
    setTextScale = function(s)   scale_set = s end,
    getSize      = function()    return 51, 19 end,
    setCursorPos = function()    end,
    setTextColor = function()    end,
    write        = function(text) table.insert(written, tostring(text)) end,
    _cleared     = function()    return cleared end,
    _scale       = function()    return scale_set end,
    _written     = function()    return written end,
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

function M.make_loopback_pair()
  local inbox_a, inbox_b = {}, {}
  local function make(my_inbox, their_inbox, partner_id)
    return {
      send    = function(_, msg) table.insert(their_inbox, msg) end,
      receive = function(_)
        local msg = table.remove(my_inbox, 1)
        if msg then return partner_id, msg end
      end,
      _inbox  = my_inbox,
    }
  end
  return make(inbox_a, inbox_b, 2), make(inbox_b, inbox_a, 1)
end

return M
