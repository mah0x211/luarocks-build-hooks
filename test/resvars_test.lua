require("luacov")

-- Load module under test
local resvars = require("luarocks.build.hooks.lib.resvars")

-- Mock os.getenv for testing
local mock_env = {}
local getenv = os.getenv
os.getenv = function(k) -- luacheck: ignore
    return mock_env[k] or getenv(k)
end

-- Test helpers

local function run_test(name, func)
    io.write("Running " .. name .. "... ")
    mock_env = {}
    local status, err = xpcall(func, debug.traceback)
    if status then
        print("OK")
    else
        print("FAIL")
        print(err)
        os.exit(1)
    end
end

local function assert_equal(expected, actual, msg)
    if expected ~= actual then
        error((msg or "") .. " Expected " .. tostring(expected) .. ", got " ..
                  tostring(actual), 2)
    end
end

local function assert_nil(val, msg)
    if val ~= nil then
        error((msg or "") .. " Expected nil, got " .. tostring(val), 2)
    end
end

local function assert_error(pattern, result, errmsg)
    if result ~= nil then
        error("Expected error matching " .. tostring(pattern) ..
                  ", got result: " .. tostring(result), 2)
    end
    if errmsg == nil then
        error("Expected error matching " .. tostring(pattern) ..
                  ", but errmsg is nil", 2)
    end
    if pattern and not tostring(errmsg):match(pattern) then
        error("Expected error matching " .. tostring(pattern) .. ", got: " ..
                  tostring(errmsg), 2)
    end
end

-- ── string input ──────────────────────────────────────────────────────────────

run_test("$(VAR) resolved from variables", function()
    local result, err = resvars("$(FOO)", {
        FOO = "bar",
    })
    assert_nil(err)
    assert_equal("bar", result)
end)

run_test("$(VAR) in the middle of a string", function()
    local result, err = resvars("prefix-$(FOO)-suffix", {
        FOO = "bar",
    })
    assert_nil(err)
    assert_equal("prefix-bar-suffix", result)
end)

run_test("multiple $(VAR) expressions", function()
    local result, err = resvars("$(A) and $(B)", {
        A = "foo",
        B = "baz",
    })
    assert_nil(err)
    assert_equal("foo and baz", result)
end)

run_test("$(VAR) missing → error", function()
    local result, err = resvars("$(FOO)", {})
    assert_error("unresolved required variable", result, err)
end)

run_test("$(VAR)? resolved from variables", function()
    local result, err = resvars("$(FOO)?", {
        FOO = "bar",
    })
    assert_nil(err)
    assert_equal("bar", result)
end)

run_test("$(VAR)? missing → empty string", function()
    local result, err = resvars("$(FOO)?", {})
    assert_nil(err)
    assert_equal("", result)
end)

run_test("$(VAR)? missing → replaces only the token", function()
    local result, err = resvars("prefix-$(FOO)?-suffix", {})
    assert_nil(err)
    assert_equal("prefix--suffix", result)
end)

run_test("$(VAR|env) resolved from variables (env ignored)", function()
    mock_env["FOO"] = "from_env"
    local result, err = resvars("$(FOO|env)", {
        FOO = "from_vars",
    })
    assert_nil(err)
    assert_equal("from_vars", result)
end)

run_test("$(VAR|env) falls back to env when not in variables", function()
    mock_env["FOO"] = "from_env"
    local result, err = resvars("$(FOO|env)", {})
    assert_nil(err)
    assert_equal("from_env", result)
end)

run_test("$(VAR|env) missing in both → error", function()
    local result, err = resvars("$(FOO|env)", {})
    assert_error("unresolved required variable", result, err)
end)

run_test("$(VAR|env)? missing in both → empty string", function()
    local result, err = resvars("$(FOO|env)?", {})
    assert_nil(err)
    assert_equal("", result)
end)

run_test("$(VAR:env) resolved from env", function()
    mock_env["FOO"] = "from_env"
    local result, err = resvars("$(FOO:env)", {
        FOO = "from_vars",
    })
    assert_nil(err)
    assert_equal("from_env", result)
end)

run_test("$(VAR:env) not in env → error", function()
    local result, err = resvars("$(FOO:env)", {
        FOO = "from_vars",
    })
    assert_error("unresolved required variable", result, err)
end)

run_test("$(VAR:env)? not in env → empty string", function()
    local result, err = resvars("$(FOO:env)?", {
        FOO = "from_vars",
    })
    assert_nil(err)
    assert_equal("", result)
end)

run_test("$(VAR:env)? resolved from env", function()
    mock_env["FOO"] = "from_env"
    local result, err = resvars("$(FOO:env)?", {})
    assert_nil(err)
    assert_equal("from_env", result)
end)

run_test("unknown modifier is left unchanged", function()
    local result, err = resvars("$(FOO|bad)", {
        FOO = "bar",
    })
    assert_nil(err)
    assert_equal("$(FOO|bad)", result)
end)

run_test("non-identifier name (with hyphen) is left unchanged", function()
    local result, err = resvars("$(FOO-BAR)", {
        ["FOO-BAR"] = "bar",
    })
    assert_nil(err)
    assert_equal("$(FOO-BAR)", result)
end)

run_test("single-pass: variable value with $(VAR) is not re-expanded",
         function()
    local result, err = resvars("$(FOO)", {
        FOO = "$(BAR)",
        BAR = "baz",
    })
    assert_nil(err)
    assert_equal("$(BAR)", result)
end)

run_test("no expressions → string is unchanged", function()
    local result, err = resvars("no variables here", {
        FOO = "bar",
    })
    assert_nil(err)
    assert_equal("no variables here", result)
end)

run_test("empty string → empty string", function()
    local result, err = resvars("", {})
    assert_nil(err)
    assert_equal("", result)
end)

run_test("variable value is empty string → resolved to empty string", function()
    local result, err = resvars("$(FOO)", {
        FOO = "",
    })
    assert_nil(err)
    assert_equal("", result)
end)

run_test("non-string variable value treated as missing (required)", function()
    local result, err = resvars("$(FOO)", {
        FOO = 42,
    })
    assert_error("unresolved required variable", result, err)
end)

run_test("non-string variable value treated as missing (optional)", function()
    local result, err = resvars("$(FOO)?", {
        FOO = 42,
    })
    assert_nil(err)
    assert_equal("", result)
end)

run_test("nil variables defaults to empty table (all optional)", function()
    local result, err = resvars("$(FOO)?", nil)
    assert_nil(err)
    assert_equal("", result)
end)

run_test("$(VAR) where variables is nil treats variable as missing", function()
    local result, err = resvars("$(FOO)", nil)
    assert_error("unresolved required variable", result, err)
end)

run_test("expression with only ? in inner is left unchanged", function()
    local result, err = resvars("$(?)", {})
    assert_nil(err)
    assert_equal("$(?)", result)
end)

run_test("error message includes variable expression", function()
    local result, err = resvars("$(MY_VAR)", {})
    assert_error("%$%(MY_VAR%)", result, err)
end)

run_test("error message includes modifier in expression", function()
    local result, err = resvars("$(MY_VAR|env)", {})
    assert_error("%$%(MY_VAR|env%)", result, err)
end)

-- ── table input ───────────────────────────────────────────────────────────────

run_test("table: resolves string values in-place", function()
    local t = {
        a = "$(FOO)",
        b = "$(BAR)",
    }
    local result, err = resvars(t, {
        FOO = "foo",
        BAR = "bar",
    })
    assert_nil(err)
    assert_equal(t, result) -- same table returned
    assert_equal("foo", t.a)
    assert_equal("bar", t.b)
end)

run_test("table: resolves nested table string values", function()
    local t = {
        nested = {
            x = "$(FOO)",
        },
    }
    local result, err = resvars(t, {
        FOO = "resolved",
    })
    assert_nil(err)
    assert_equal(t, result)
    assert_equal("resolved", t.nested.x)
end)

run_test("table: non-string values are left unchanged", function()
    local inner = {}
    local t = {
        num = 42,
        bool = true,
        tbl = inner,
    }
    local result, err = resvars(t, {})
    assert_nil(err)
    assert_equal(t, result)
    assert_equal(42, t.num)
    assert_equal(true, t.bool)
    assert_equal(inner, t.tbl)
end)

run_test("table: error returned for required missing variable", function()
    local t = {
        a = "$(MISSING)",
    }
    local result, err = resvars(t, {})
    assert_error("unresolved required variable", result, err)
end)

run_test("table: nil variables defaults to empty table", function()
    local t = {
        a = "$(FOO)?",
    }
    local result, err = resvars(t, nil)
    assert_nil(err)
    assert_equal(t, result)
    assert_equal("", t.a)
end)

-- ── invalid input ─────────────────────────────────────────────────────────────

run_test("invalid type (number) → error", function()
    local result, err = resvars(42, {})
    assert_error("expected string or table", result, err)
end)

run_test("invalid type (boolean) → error", function()
    local result, err = resvars(true, {})
    assert_error("expected string or table", result, err)
end)
