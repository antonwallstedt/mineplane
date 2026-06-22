--- Fixed-size circular buffer for time-series samples.
--- Each sample is a {t, v} pair. Oldest sample is overwritten when full.
---
--- Internal layout:
---   _buffer        : table, 1-indexed, length == _capacity
---   _head       : index of the *next* write slot (1-based, wraps via modulo)
---   _count      : number of live samples (0 .. _capacity)
---   _capacity   : fixed capacity

local RingBuffer = {}
RingBuffer.__index = RingBuffer

--- @param capacity integer  Must be >= 1
--- @return RingBuffer
function RingBuffer.new(capacity)
  assert(
    type(capacity) == "number" and capacity >= 1 and math.floor(capacity) == capacity,
    "capacity must be a positive integer"
  )
  local self = setmetatable({}, RingBuffer)
  self._capacity = capacity
  self._buffer = {}
  self._head = 1
  self._count = 0
  return self
end

--- Push a new sample. Overwrites oldest when full.
--- @param time number  timestamp
--- @param value number  value
function RingBuffer:push(time, value)
  self._buffer[self._head] = { time = time, value = value }
  self._head = (self._head % self._capacity) + 1
  if self._count < self._capacity then
    self._count = self._count + 1
  end
  return self
end

--- Number of live samples currently stored.
--- @return integer
function RingBuffer:count()
  return self._count
end

--- Fixed capacity of this buffer.
--- @return integer
function RingBuffer:capacity()
  return self._capacity
end

--- True when count() == 0.
--- @return boolean
function RingBuffer:is_empty()
  return self._count == 0
end

--- Physical buffer index for a logical offset from the oldest live sample.
--- offset 0 = oldest, offset _count-1 = newest.
function RingBuffer:_index_at(offset)
  return ((self._head - 1 + self._capacity - self._count + offset) % self._capacity) + 1
end

--- Most recent sample, or nil if empty.
--- @return {time:number, value:number}|nil
function RingBuffer:latest()
  if self._count == 0 then return nil end
  return self._buffer[self:_index_at(self._count - 1)]
end

--- Oldest live sample, or nil if empty.
--- @return {time:number, value:number}|nil
function RingBuffer:oldest()
  if self._count == 0 then return nil end
  return self._buffer[self:_index_at(0)]
end

--- Returns up to n most recent samples in oldest-first order.
--- If n > count(), returns all available samples (clamps silently).
--- @param n integer
--- @return {time:number, value:number}[]
function RingBuffer:last(n)
  n = math.min(n, self._count)
  local result = {}
  for i = 1, n do
    result[i] = self._buffer[self:_index_at(self._count - n + i - 1)]
  end
  return result
end

--- Returns all live samples in oldest-first order.
--- @return {time:number, value:number}[]
function RingBuffer:all()
  return self:last(self._count)
end

--- Returns an iterator over all live samples, oldest first.
--- for sample in buf:iter() do ... end
--- @return function
function RingBuffer:iter()
  local remaining = self._count
  local index = self:_index_at(0)
  return function()
    if remaining == 0 then return nil end
    local sample = self._buffer[index]
    index = (index % self._capacity) + 1
    remaining = remaining - 1
    return sample
  end
end

--- Removes all samples. Capacity is unchanged.
function RingBuffer:clear()
  self._buffer = {}
  self._head = 1
  self._count = 0
end

return RingBuffer
