require("luacov")

local unpack = unpack or table.unpack -- luacheck: ignore

-- Mock framework
local function mock(name, value)
    package.loaded[name] = value
end

-- Mock luarocks.util
local mock_util = {
    printout = function()
    end,
}
mock("luarocks.util", mock_util)

-- Mock configh.generate: replaced per test via mock_generate.func
local mock_generate = {
    calls = {},
    result = nil, -- {report} on success, or {nil, "err"} on failure
}
mock_generate.reset = function()
    mock_generate.calls = {}
    mock_generate.result = nil
end
mock("configh.generate", function(cfg, label, stdout)
    mock_generate.calls[#mock_generate.calls + 1] = {
        cfg = cfg,
        label = label,
        stdout = stdout,
    }
    if mock_generate.result then
        return unpack(mock_generate.result)
    end
    return {} -- default: success with empty report
end)

-- Load module under test (after mocks are in place)
local run_configh = require("luarocks.build.hooks.configh")

-- Test helpers

local function run_test(name, func)
    io.write("Running " .. name .. "... ")
    mock_generate.reset()
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

local function assert_not_nil(val, msg)
    if val == nil then
        error((msg or "") .. " Expected non-nil value", 2)
    end
end

local function assert_match(pattern, str, msg)
    if not tostring(str):match(pattern) then
        error((msg or "") .. " Expected " .. tostring(str) ..
                  " to match pattern " .. tostring(pattern), 2)
    end
end

local function assert_error(func, pattern, msg)
    local ok, err = pcall(func)
    if ok then
        error((msg or "") .. " Expected an error to be raised", 2)
    end
    if pattern and not tostring(err):match(pattern) then
        error((msg or "") .. " Error " .. tostring(err) ..
                  " did not match pattern " .. tostring(pattern), 2)
    end
end

-- Helper: build a minimal rockspec
local function make_rockspec(modules, variables)
    return {
        variables = variables or {},
        build = {
            modules = modules or {},
        },
    }
end

-- =============================================================================
-- Module scanning tests (s09)
-- =============================================================================

run_test("skips rockspec with no build.modules", function()
    run_configh({
        variables = {},
        build = {},
    })
    assert_equal(0, #mock_generate.calls, "generate should not be called")
end)

run_test("skips rockspec when build is missing", function()
    run_configh({
        variables = {},
    })
    assert_equal(0, #mock_generate.calls, "generate should not be called")
end)

run_test("skips modules that are strings (source file paths)", function()
    local rockspec = make_rockspec({
        ["mymod"] = "src/mymod.c",
    })
    run_configh(rockspec)
    assert_equal(0, #mock_generate.calls, "generate should not be called")
end)

run_test("skips table modules without a configh field", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            sources = {
                "src/mymod.c",
            },
            incdirs = {
                "/usr/include",
            },
        },
    })
    run_configh(rockspec)
    assert_equal(0, #mock_generate.calls, "generate should not be called")
end)

run_test("errors when configh field is a string (not a table)", function()
    assert_error(function()
        run_configh(make_rockspec({
            ["mymod"] = {
                configh = "not-a-table",
            },
        }))
    end, 'configh must be a table, got string',
                 "should error with type information")
end)

run_test("errors when configh field is a boolean (not a table)", function()
    assert_error(function()
        run_configh(make_rockspec({
            ["mymod"] = {
                configh = true,
            },
        }))
    end, 'configh must be a table, got boolean',
                 "should error with type information")
end)

run_test("processes a module that has a configh table", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            sources = {
                "src/mymod.c",
            },
            configh = {
                output = "src/config.h",
            },
        },
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls, "generate should be called once")
    assert_equal("src/config.h", mock_generate.calls[1].cfg.output)
end)

run_test("stores report in module.configh.report", function()
    local fake_report = {
        ['sys/event.h'] = {
            is_exists = true,
            kevent = true,
        },
    }
    mock_generate.result = {
        fake_report,
    }
    local configh_cfg = {
        output = "src/config.h",
    }
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = configh_cfg,
        },
    })
    run_configh(rockspec)
    assert_equal(fake_report, configh_cfg.report,
                 "report should be stored in module.configh.report")
end)

run_test("report is not passed to generate (copy excludes it)", function()
    local fake_report = {
        ['sys/event.h'] = {
            is_exists = true,
        },
    }
    mock_generate.result = {
        fake_report,
    }
    local configh_cfg = {
        output = "src/config.h",
    }
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = configh_cfg,
        },
    })
    run_configh(rockspec)
    -- Second call: report is now set in configh_cfg; must not be passed to generate
    mock_generate.reset()
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    assert_nil(mock_generate.calls[1].cfg.report,
               "report field must not be passed to generate")
end)

run_test("processes multiple modules with configh tables", function()
    local rockspec = make_rockspec({
        ["mod_a"] = {
            configh = {
                output = "src/config_a.h",
            },
        },
        ["mod_b"] = "src/mod_b.c", -- string: should be skipped
        ["mod_c"] = {
            configh = {
                output = "src/config_c.h",
            },
        },
    })
    run_configh(rockspec)
    assert_equal(2, #mock_generate.calls, "generate should be called twice")
end)

-- =============================================================================
-- cfg copy / non-mutation tests (s10)
-- =============================================================================

run_test("does not mutate the original module.configh table", function()
    local original_configh = {
        output = "src/config.h",
        libs = {
            "ssl crypto",
        },
        incdirs = {
            "/usr/include",
        },
    }
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = original_configh,
        },
    }, {
        MYVAR = "resolved",
    })
    run_configh(rockspec)

    -- Original must be unchanged
    assert_equal("src/config.h", original_configh.output)
    assert_equal(1, #original_configh.libs)
    assert_equal("ssl crypto", original_configh.libs[1])
    assert_equal(1, #original_configh.incdirs)
    assert_equal("/usr/include", original_configh.incdirs[1])
end)

run_test("cfg passed to generate is a distinct table from module.configh",
         function()
    local original_configh = {
        output = "src/config.h",
    }
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = original_configh,
        },
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    -- The table passed to generate must be a copy, not the original
    local passed_cfg = mock_generate.calls[1].cfg
    assert_not_nil(passed_cfg)
    if passed_cfg == original_configh then
        error("generate received the original table, not a copy")
    end
end)

-- =============================================================================
-- $(VAR) resolution tests (s11)
-- =============================================================================

run_test("resolves known $(VAR) in string values", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "$(PREFIX)/include/config.h",
                incdirs = {
                    "$(INC_DIR)",
                },
            },
        },
    }, {
        PREFIX = "/usr/local",
        INC_DIR = "/usr/include/mylib",
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local cfg = mock_generate.calls[1].cfg
    assert_equal("/usr/local/include/config.h", cfg.output)
    assert_equal("/usr/include/mylib", cfg.incdirs[1])
end)

run_test("leaves unknown $(VAR) unchanged", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "$(UNKNOWN)/config.h",
            },
        },
    }, {})
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    assert_equal("$(UNKNOWN)/config.h", mock_generate.calls[1].cfg.output)
end)

run_test("resolves $(VAR) in nested table string values", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "src/config.h",
                libdirs = {
                    "$(LIB_DIR)/mylib",
                },
                libs = {
                    "$(MYLIB)",
                },
            },
        },
    }, {
        LIB_DIR = "/usr/lib",
        MYLIB = "ssl",
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local cfg = mock_generate.calls[1].cfg
    assert_equal("/usr/lib/mylib", cfg.libdirs[1])
    assert_equal("ssl", cfg.libs[1])
end)

run_test("resolves multiple $(VAR) references in one string", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "$(BASE)/$(SUB)/config.h",
            },
        },
    }, {
        BASE = "/opt",
        SUB = "myapp",
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    assert_equal("/opt/myapp/config.h", mock_generate.calls[1].cfg.output)
end)

-- =============================================================================
-- cfg.libs normalization tests (s12)
-- =============================================================================

run_test("splits space-separated libs into individual entries", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "src/config.h",
                libs = {
                    "ssl crypto",
                },
            },
        },
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local libs = mock_generate.calls[1].cfg.libs
    assert_equal(2, #libs, "libs should have 2 entries after split")
    assert_equal("ssl", libs[1])
    assert_equal("crypto", libs[2])
end)

run_test("leaves single-name lib entries unchanged", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "src/config.h",
                libs = {
                    "ssl",
                    "crypto",
                },
            },
        },
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local libs = mock_generate.calls[1].cfg.libs
    assert_equal(2, #libs)
    assert_equal("ssl", libs[1])
    assert_equal("crypto", libs[2])
end)

run_test("skips empty string entries in libs", function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "src/config.h",
                libs = {
                    "ssl",
                    "  ",
                    "crypto",
                },
            },
        },
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local libs = mock_generate.calls[1].cfg.libs
    assert_equal(2, #libs)
    assert_equal("ssl", libs[1])
    assert_equal("crypto", libs[2])
end)

run_test("libs normalization handles mix of single and multi-name entries",
         function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "src/config.h",
                libs = {
                    "ssl crypto",
                    "z",
                },
            },
        },
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local libs = mock_generate.calls[1].cfg.libs
    assert_equal(3, #libs)
    assert_equal("ssl", libs[1])
    assert_equal("crypto", libs[2])
    assert_equal("z", libs[3])
end)

run_test("libs normalization after VAR resolution splits expanded values",
         function()
    local rockspec = make_rockspec({
        ["mymod"] = {
            configh = {
                output = "src/config.h",
                libs = {
                    "$(MYLIBS)",
                },
            },
        },
    }, {
        MYLIBS = "ssl crypto",
    })
    run_configh(rockspec)
    assert_equal(1, #mock_generate.calls)
    local libs = mock_generate.calls[1].cfg.libs
    assert_equal(2, #libs)
    assert_equal("ssl", libs[1])
    assert_equal("crypto", libs[2])
end)

-- =============================================================================
-- Error propagation tests (s13)
-- =============================================================================

run_test("propagates flush error from configh.generate with module label",
         function()
    mock_generate.result = {
        nil,
        "failed to write output file",
    }
    assert_error(function()
        run_configh(make_rockspec({
            ["mymod"] = {
                configh = {
                    output = "src/config.h",
                },
            },
        }))
    end, "mymod", "error message should contain module name")
end)

run_test("propagates assert error from configh.generate (missing output)",
         function()
    -- Replace mock to call the real error path (missing output field)
    -- We simulate this by making our mock raise an error
    package.loaded["configh.generate"] =
        function(cfg, label)
            assert(type(cfg.output) == "string",
                   label .. ".output must be a string")
            return {}
        end
    -- Reload the hook module to pick up the updated mock
    package.loaded["luarocks.build.hooks.configh"] = nil
    local hook = require("luarocks.build.hooks.configh")
    assert_error(function()
        hook(make_rockspec({
            ["mymod"] = {
                configh = {
                    -- output intentionally missing
                },
            },
        }))
    end, "output must be a string")
    -- Restore original mock and reload
    package.loaded["configh.generate"] =
        function(cfg, label, stdout)
            mock_generate.calls[#mock_generate.calls + 1] = {
                cfg = cfg,
                label = label,
                stdout = stdout,
            }
            if mock_generate.result then
                return table.unpack(mock_generate.result)
            end
            return {}
        end
    package.loaded["luarocks.build.hooks.configh"] = nil
    run_configh = require("luarocks.build.hooks.configh")
end)

run_test("label passed to generate contains the module name", function()
    run_configh(make_rockspec({
        ["myspecialmod"] = {
            configh = {
                output = "src/config.h",
            },
        },
    }))
    assert_equal(1, #mock_generate.calls)
    assert_match("myspecialmod", mock_generate.calls[1].label,
                 "label should contain module name")
end)

print("\nAll configh hook tests passed!")
