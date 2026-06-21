-- Smoke-test for the test runner itself.
-- Every assertion here should pass; the runner will self-verify.

describe("assert_lib.equals", function()
  it("passes when values are equal", function()
    assert.equals(1, 1)
    assert.equals("hello", "hello")
    assert.equals(true, true)
  end)

  it("fails when values differ", function()
    assert.error_matches(function()
      assert.equals(1, 2)
    end, "equals failed")
  end)
end)

describe("assert_lib.near", function()
  it("passes within epsilon", function()
    assert.near(0.1 + 0.2, 0.3, 1e-9)
  end)

  it("fails outside epsilon", function()
    assert.error_matches(function()
      assert.near(1.0, 2.0, 1e-9)
    end, "near failed")
  end)
end)

describe("assert_lib.error_matches", function()
  it("catches expected errors", function()
    assert.error_matches(function()
      error("something went wrong")
    end, "went wrong")
  end)

  it("fails when no error is raised", function()
    assert.error_matches(function()
      assert.error_matches(function() end, "anything")
    end, "no error was raised")
  end)
end)
