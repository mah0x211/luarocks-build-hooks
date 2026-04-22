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

run_test("$(VAR)? missing → nil", function()
    local result, err = resvars("$(FOO)?", {})
    assert_nil(err)
    assert_nil(result)
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

run_test("$(VAR|env)? missing in both → nil", function()
    local result, err = resvars("$(FOO|env)?", {})
    assert_nil(err)
    assert_nil(result)
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

run_test("$(VAR:env)? not in env → nil", function()
    local result, err = resvars("$(FOO:env)?", {
        FOO = "from_vars",
    })
    assert_nil(err)
    assert_nil(result)
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

run_test("empty string → nil", function()
    local result, err = resvars("", {})
    assert_nil(err)
    assert_nil(result)
end)

run_test(
    "variable value is empty string → treated as missing (required) → error",
    function()
        local result, err = resvars("$(FOO)", {
            FOO = "",
        })
        assert_error("unresolved required variable", result, err)
    end)

run_test(
    "variable value is empty string → treated as missing (optional) → nil",
    function()
        local result, err = resvars("$(FOO)?", {
            FOO = "",
        })
        assert_nil(err)
        assert_nil(result)
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
    assert_nil(result)
end)

run_test("nil variables defaults to empty table (all optional)", function()
    local result, err = resvars("$(FOO)?", nil)
    assert_nil(err)
    assert_nil(result)
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

run_test(
    "string with multiple required missing vars → first error reported (early exit)",
    function()
        -- The gsub callback sets errmsg on the first missing required var and then
        -- returns early (without setting errmsg again) for any subsequent variable.
        local result, err = resvars("$(MISSING1) and $(MISSING2)", {})
        assert_error("MISSING1", result, err)
    end)

-- ── table input ───────────────────────────────────────────────────────────────

run_test("table: resolves string values, returns new table", function()
    local t = {
        a = "$(FOO)",
        b = "$(BAR)",
    }
    local result, err = resvars(t, {
        FOO = "foo",
        BAR = "bar",
    })
    assert_nil(err)
    assert_equal("foo", result.a)
    assert_equal("bar", result.b)
    -- input must not be modified
    assert_equal("$(FOO)", t.a)
    assert_equal("$(BAR)", t.b)
end)

run_test("table: resolves nested table string values in new table", function()
    local t = {
        nested = {
            x = "$(FOO)",
        },
    }
    local result, err = resvars(t, {
        FOO = "resolved",
    })
    assert_nil(err)
    assert_equal("resolved", result.nested.x)
    -- input must not be modified
    assert_equal("$(FOO)", t.nested.x)
end)

run_test("table: non-string values are preserved in new table", function()
    local inner = {}
    local t = {
        num = 42,
        bool = true,
        tbl = inner,
    }
    local result, err = resvars(t, {})
    assert_nil(err)
    assert_equal(42, result.num)
    assert_equal(true, result.bool)
    -- input must not be modified
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

run_test("table: optional nil var dropped from result table", function()
    local t = {
        a = "$(FOO)?",
    }
    local result, err = resvars(t, nil)
    assert_nil(err)
    assert_nil(result.a, "optional key with missing var should be absent")
    -- input must not be modified
    assert_equal("$(FOO)?", t.a)
end)

run_test("table: returns new table (not same reference as input)", function()
    local t = {
        a = "hello",
    }
    local result, err = resvars(t, {})
    assert_nil(err)
    if result == t then
        error("resvars should return a new table, not the same reference")
    end
    assert_equal("hello", result.a)
end)

run_test("table: array element resolving to nil is dropped (dense rebuild)",
         function()
    local t = {
        "$(PRESENT)",
        "$(MISSING)?",
        "literal",
    }
    local result, err = resvars(t, {
        PRESENT = "found",
    })
    assert_nil(err)
    assert_equal(2, #result)
    assert_equal("found", result[1])
    assert_equal("literal", result[2])
end)

run_test("table: map key resolving to nil is dropped", function()
    local t = {
        keep = "hello",
        drop = "$(MISSING)?",
    }
    local result, err = resvars(t, {})
    assert_nil(err)
    assert_equal("hello", result.keep)
    assert_nil(result.drop)
end)

run_test("table: empty child table is preserved", function()
    local t = {
        sub = {},
    }
    local result, err = resvars(t, {})
    assert_nil(err)
    assert_equal("table", type(result.sub))
    assert_equal(0, #result.sub)
end)

run_test("table: array element that is a table → nested rebuild", function()
    local t = {
        "prefix",
        {
            key = "$(VAR)",
        },
        "suffix",
    }
    local result, err = resvars(t, {
        VAR = "hello",
    })
    assert_nil(err)
    assert_equal(3, #result)
    assert_equal("prefix", result[1])
    assert_equal("table", type(result[2]))
    assert_equal("hello", result[2].key)
    assert_equal("suffix", result[3])
end)

run_test(
    "table: array element that is a table with missing required var → error",
    function()
        local t = {
            {
                key = "$(MISSING)",
            },
        }
        local result, err = resvars(t, {})
        assert_error("MISSING", result, err)
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
