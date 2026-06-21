local RingBuffer = require("lib.ring_buffer")

describe("RingBuffer.new", function()
  it("rejects capacity < 1", function()
    assert.error_matches(function()
      RingBuffer.new(0)
    end, "positive integer")
  end)

  it("starts empty", function()
    local ring_buffer = RingBuffer.new(4)
    assert.equals(ring_buffer:count(), 0)
    assert.truthy(ring_buffer:is_empty())
    assert.equals(ring_buffer:capacity(), 4)
  end)
end)

describe("RingBuffer basic push", function()
  it("pushes and counts", function()
    local ring_buffer = RingBuffer.new(4)

    ring_buffer:push(1, 10)
    assert.equals(ring_buffer:count(), 1)

    ring_buffer:push(2, 20)
    assert.equals(ring_buffer:count(), 2)
  end)

  it("latest and oldest on empty buffer return nil", function()
    local ring_buffer = RingBuffer.new(4)
    assert.is_nil(ring_buffer:latest())
    assert.is_nil(ring_buffer:oldest())
  end)

  it("latest and oldest track correctly before wrap", function()
    local ring_buffer = RingBuffer.new(4)

    ring_buffer:push(1, 10)
    assert.same(ring_buffer:latest(), { time = 1, value = 10 })
    assert.same(ring_buffer:oldest(), { time = 1, value = 10 })

    ring_buffer:push(2, 20)
    assert.same(ring_buffer:latest(), { time = 2, value = 20 })
    assert.same(ring_buffer:oldest(), { time = 1, value = 10 })
  end)
end)

describe("RingBuffer wrap-around", function()
  it("count stays capped at capacity when overflowing", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 6 do
      ring_buffer:push(i, i * 10)
    end
    assert.equals(ring_buffer:count(), 4)
  end)

  it("latest and oldest after wrap-around", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 6 do
      ring_buffer:push(i, i * 10)
    end
    assert.same(ring_buffer:latest(), { time = 6, value = 60 })
    assert.same(ring_buffer:oldest(), { time = 3, value = 30 })
  end)

  it("last(n) after wrap-around", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 6 do
      ring_buffer:push(i, i * 10)
    end
    assert.same(ring_buffer:last(2), { { time = 5, value = 50 }, { time = 6, value = 60 } })
  end)

  it("all() after wrap-around", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 6 do
      ring_buffer:push(i, i * 10)
    end
    assert.same(ring_buffer:all(), {
      { time = 3, value = 30 },
      { time = 4, value = 40 },
      { time = 5, value = 50 },
      { time = 6, value = 60 },
    })
  end)

  it("iter() after wrap-around", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 6 do
      ring_buffer:push(i, i * 10)
    end
    local samples = {}
    for sample in ring_buffer:iter() do
      table.insert(samples, sample)
    end
    assert.same(samples, {
      { time = 3, value = 30 },
      { time = 4, value = 40 },
      { time = 5, value = 50 },
      { time = 6, value = 60 },
    })
  end)

  it("heavy overflow: push capacity*3 items, only last capacity survive", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 12 do
      ring_buffer:push(i, i * 10)
    end
    assert.equals(ring_buffer:count(), 4)
    assert.same(ring_buffer:oldest(), { time = 9, value = 90 })
    assert.same(ring_buffer:latest(), { time = 12, value = 120 })
    assert.same(ring_buffer:all(), {
      { time = 9,  value = 90 },
      { time = 10, value = 100 },
      { time = 11, value = 110 },
      { time = 12, value = 120 },
    })
  end)
end)

describe("RingBuffer:last", function()
  it("returns samples in oldest-first order", function()
    local ring_buffer = RingBuffer.new(4)
    ring_buffer:push(1, 10)
    ring_buffer:push(2, 20)
    ring_buffer:push(3, 30)
    assert.same(ring_buffer:last(3), {
      { time = 1, value = 10 },
      { time = 2, value = 20 },
      { time = 3, value = 30 },
    })
  end)

  it("clamps silently when n > count", function()
    local ring_buffer = RingBuffer.new(4)
    ring_buffer:push(1, 10)
    ring_buffer:push(2, 20)
    local result = ring_buffer:last(10)
    assert.equals(#result, 2)
    assert.same(result, { { time = 1, value = 10 }, { time = 2, value = 20 } })
  end)

  it("returns empty table when n == 0", function()
    local ring_buffer = RingBuffer.new(4)
    ring_buffer:push(1, 10)
    assert.same(ring_buffer:last(0), {})
  end)

  it("n == count returns all samples", function()
    local ring_buffer = RingBuffer.new(4)
    ring_buffer:push(1, 10)
    ring_buffer:push(2, 20)
    assert.same(ring_buffer:last(2), ring_buffer:all())
  end)

  it("n < count returns last n samples", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 4 do
      ring_buffer:push(i, i * 10)
    end
    assert.same(ring_buffer:last(2), {
      { time = 3, value = 30 },
      { time = 4, value = 40 },
    })
  end)
end)

describe("RingBuffer:all and :iter", function()
  it("all() returns empty table on empty buffer", function()
    local ring_buffer = RingBuffer.new(4)
    assert.same(ring_buffer:all(), {})
  end)

  it("iter() on empty buffer yields nothing", function()
    local ring_buffer = RingBuffer.new(4)
    local count = 0
    for _ in ring_buffer:iter() do
      count = count + 1
    end
    assert.equals(count, 0)
  end)

  it("iter() produces same sequence as all()", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 6 do
      ring_buffer:push(i, i * 10)
    end
    local from_iter = {}
    for sample in ring_buffer:iter() do
      table.insert(from_iter, sample)
    end
    assert.same(from_iter, ring_buffer:all())
  end)
end)

describe("RingBuffer:clear", function()
  it("empties the buffer", function()
    local ring_buffer = RingBuffer.new(4)
    for i = 1, 4 do
      ring_buffer:push(i, i * 10)
    end
    ring_buffer:clear()
    assert.equals(ring_buffer:count(), 0)
    assert.truthy(ring_buffer:is_empty())
    assert.is_nil(ring_buffer:latest())
    assert.is_nil(ring_buffer:oldest())
    assert.same(ring_buffer:all(), {})
  end)

  it("can push again after clear", function()
    local ring_buffer = RingBuffer.new(4)
    ring_buffer:push(1, 10)
    ring_buffer:clear()
    ring_buffer:push(2, 20)
    assert.equals(ring_buffer:count(), 1)
    assert.same(ring_buffer:latest(), { time = 2, value = 20 })
  end)
end)

describe("RingBuffer capacity == 1", function()
  it("only ever holds one sample", function()
    local ring_buffer = RingBuffer.new(1)
    ring_buffer:push(1, 10)
    ring_buffer:push(2, 20)
    assert.equals(ring_buffer:count(), 1)
    assert.same(ring_buffer:latest(), { time = 2, value = 20 })
    assert.same(ring_buffer:oldest(), { time = 2, value = 20 })
  end)
end)
