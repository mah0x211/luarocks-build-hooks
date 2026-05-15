require("luacov")

-- Load module under test
local resolve_modvars = require("luarocks.build.hooks.lib.resmodvars")

-- Test helpers

local function run_test(name, func)
    io.write("Running " .. name .. "... ")
    local status, err = xpcall(func, debug.traceback)
    if status then
        print("OK")
    else
        print("FAIL")
        print(err)
        os.exit(1)
    end
end

local function assert_true(val, msg)
    if not val then
        error((msg or "Expected true") .. ", got " .. tostring(val))
    end
end

local function assert_false(val, msg)
    if val then
        error((msg or "Expected false") .. ", got " .. tostring(val))
    end
end

local function assert_equal(expected, actual, msg)
    if expected ~= actual then
        error((msg or "") .. " Expected " .. tostring(expected) .. ", got " ..
                  tostring(actual))
    end
end

local function assert_nil(val, msg)
    if val ~= nil then
        error((msg or "") .. " Expected nil, got " .. tostring(val))
    end
end

local function assert_deep_equal(expected, actual, msg)
    if type(expected) ~= type(actual) then
        error((msg or "") .. " type mismatch: expected " .. type(expected) ..
                  ", got " .. type(actual))
    end
    if type(expected) ~= 'table' then
        if expected ~= actual then
            error(
                (msg or "") .. " Expected " .. tostring(expected) .. ", got " ..
                    tostring(actual))
        end
        return
    end
    for k, v in pairs(expected) do
        assert_deep_equal(v, actual[k], (msg or "") .. "[" .. tostring(k) .. "]")
    end
    for k, _ in pairs(actual) do
        if expected[k] == nil then
            error((msg or "") .. " unexpected key " .. tostring(k))
        end
    end
end

-- ── nil/missing modules ─────────────────────────────────────────────────────

run_test("Returns true when modules is nil", function()
    local ok = resolve_modvars(nil, {})
    assert_true(ok)
end)

run_test("Returns true when modules is not a table", function()
    local ok = resolve_modvars("not a table", {})
    assert_true(ok)
end)

run_test("Returns true when modules is empty", function()
    local ok = resolve_modvars({}, {})
    assert_true(ok)
end)

-- ── string module path resolution ────────────────────────────────────────────

run_test("String module path $(VAR) resolved", function()
    local modules = {
        mymod = "$(MY_PATH)",
    }
    local ok, err = resolve_modvars(modules, {
        MY_PATH = "lib/mymod.lua",
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_equal("lib/mymod.lua", modules.mymod)
end)

run_test("String module path required $(VAR) missing → error", function()
    local modules = {
        mymod = "$(MISSING_PATH)",
    }
    local ok, err = resolve_modvars(modules, {})
    assert_false(ok)
    assert_true(err:find("MISSING_PATH") ~= nil,
                "Error should mention the variable name")
end)

run_test("String module path resolves to empty → error", function()
    local modules = {
        mymod = "$(EMPTY)?",
    }
    local ok, err = resolve_modvars(modules, {})
    assert_false(ok)
    assert_true(err:find("path resolved to empty") ~= nil,
                "Error should mention empty path")
end)

-- ── table module field resolution ───────────────────────────────────────────

run_test("sources array $(VAR) resolved", function()
    local modules = {
        mymod = {
            sources = {
                "$(SRC)",
                "src/bar.c",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        SRC = "src/foo.c",
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_equal("src/foo.c", modules.mymod.sources[1])
    assert_equal("src/bar.c", modules.mymod.sources[2])
end)

run_test("sources all-optional missing → error", function()
    local modules = {
        mymod = {
            sources = {
                "$(MISSING_SRC)?",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {})
    assert_false(ok)
    assert_true(err:find("resolved to empty") ~= nil,
                "Error should mention resolved to empty")
end)

run_test("incdirs optional missing → field deleted", function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            incdirs = {
                "$(MISSING_INC)?",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {})
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_nil(modules.mymod.incdirs,
               "incdirs should be removed when all elements resolve to nil")
end)

run_test("Required field array element with unresolvable var → error",
         function()
    local modules = {
        mymod = {
            sources = {
                "$(MISSING_SRC)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {})
    assert_false(ok)
    assert_true(err:find("MISSING_SRC") ~= nil,
                "Error should name the missing variable")
    assert_true(err:find("sources") ~= nil, "Error should name the field")
end)

run_test("Non-string/non-table module field value is passed through", function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            incdirs = true,
        },
    }
    local ok, err = resolve_modvars(modules, {})
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_equal(true, modules.mymod.incdirs,
                 "Non-string/non-table field value should be preserved as-is")
end)

-- ── non-string, non-table module entries are skipped ────────────────────────

run_test("Numeric module entries are skipped", function()
    local modules = {
        mymod = 123,
    }
    local ok, err = resolve_modvars(modules, {})
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_equal(123, modules.mymod, "Numeric module should be unchanged")
end)

-- ── multiple modules ────────────────────────────────────────────────────────

run_test("Resolves multiple modules independently", function()
    local modules = {
        mod1 = "$(PATH1)",
        mod2 = {
            sources = {
                "$(SRC)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        PATH1 = "lib/mod1.lua",
        SRC = "src/mod2.c",
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_equal("lib/mod1.lua", modules.mod1)
    assert_equal("src/mod2.c", modules.mod2.sources[1])
end)

-- ── table-valued variable resolution ────────────────────────────────────────

run_test("Standalone $(VAR) where VAR is table → array result", function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            libraries = {
                "$(MYLIBS)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        MYLIBS = {
            "ssl",
            "crypto",
        },
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "ssl",
        "crypto",
    }, modules.mymod.libraries)
end)

run_test('Embedded "-L$(VAR)" where VAR is table → mapped array', function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            libdirs = {
                "-L$(MYDIR)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        MYDIR = {
            "/usr/lib",
            "/usr/local/lib",
        },
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "-L/usr/lib",
        "-L/usr/local/lib",
    }, modules.mymod.libdirs)
end)

run_test("Mixed string + table vars: $(A)/$(B) where A=string, B=table",
         function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            libraries = {
                "$(PREFIX)/$(LIBS)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        PREFIX = "pkg",
        LIBS = {
            "ssl",
            "crypto",
        },
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "pkg/ssl",
        "pkg/crypto",
    }, modules.mymod.libraries)
end)

run_test("Multiple table-valued vars in one entry → cartesian product",
         function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            libraries = {
                "$(A)-$(B)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        A = {
            "1",
            "2",
        },
        B = {
            "3",
            "4",
        },
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "1-3",
        "1-4",
        "2-3",
        "2-4",
    }, modules.mymod.libraries)
end)

run_test("Optional $(VAR)? with empty table → nil (field deleted)", function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            incdirs = {
                "$(MYINC)?",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        MYINC = {},
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_nil(modules.mymod.incdirs, "incdirs should be deleted")
end)

run_test("Table field with mixed entries: some table vars, some plain strings",
         function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            libraries = {
                "base",
                "$(MYLIBS)",
                "extra",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        MYLIBS = {
            "ssl",
            "crypto",
        },
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "base",
        "ssl",
        "crypto",
        "extra",
    }, modules.mymod.libraries)
end)

run_test("Required field (sources) empty after table expansion → error",
         function()
    local modules = {
        mymod = {
            sources = {
                "$(MYSRC)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        MYSRC = {},
    })
    assert_false(ok)
    assert_true(err:find("unresolved required variable") ~= nil,
                "Error should mention unresolved required variable, got: " ..
                    tostring(err))
end)

run_test("Standalone table var with non-table var mixed in same array",
         function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            libraries = {
                "$(LIB_A)",
                "$(LIB_B)",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        LIB_A = {
            "ssl",
            "crypto",
        },
        LIB_B = "z",
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "ssl",
        "crypto",
        "z",
    }, modules.mymod.libraries)
end)

run_test("Embedded table var with prefix and suffix text", function()
    local modules = {
        mymod = {
            sources = {
                "src/foo.c",
            },
            incdirs = {
                "before/$(MYINC)/after",
            },
        },
    }
    local ok, err = resolve_modvars(modules, {
        MYINC = {
            "a",
            "b",
        },
    })
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "before/a/after",
        "before/b/after",
    }, modules.mymod.incdirs)
end)

run_test("Table-valued var in string module path resolves to table", function()
    local modules = {
        mymod = "$(MYLIBS)",
    }
    local ok, err = resolve_modvars(modules, {
        MYLIBS = {
            "ssl",
            "crypto",
        },
    })
    -- String module path with table-valued var resolves to the table
    assert_true(ok, "Should succeed: " .. tostring(err))
    assert_deep_equal({
        "ssl",
        "crypto",
    }, modules.mymod)
end)
