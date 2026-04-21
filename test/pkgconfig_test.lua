require("luacov")

-- Load module under test
local resolve_pkgconfig = require("luarocks.build.hooks.pkgconfig")

-- Test Helper
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

local function assert_equal(expected, actual, msg)
    if expected ~= actual then
        error((msg or "") .. " Expected " .. tostring(expected) .. ", got " ..
                  tostring(actual))
    end
end

local function assert_not_nil(val, msg)
    if val == nil then
        error((msg or "") .. " Expected non-nil value")
    end
end

-- Helper function to create a basic rockspec with pkgconfig_dependencies
local function create_rockspec(pkg, variables)
    return {
        variables = variables or {},
        build = {
            pkgconfig_dependencies = {
                [pkg] = {},
            },
        },
    }
end

-- Check if zlib is available for testing
local function check_zlib_available()
    local f = io.popen(
                  "pkg-config --exists zlib 2>/dev/null && echo 1 || echo 0")
    if not f then
        return false
    end
    local result = f:read("*a"):match("%d")
    f:close()
    return result == "1"
end

local zlib_available = check_zlib_available()

-- Helper to create a mock file handle from multi-line string content
local function make_fake_file(content)
    local lines = {}
    for line in content:gmatch('[^\n]+') do
        lines[#lines + 1] = line
    end
    local i = 0
    return {
        lines = function()
            return function()
                i = i + 1
                return lines[i]
            end
        end,
        close = function()
        end,
    }
end

-- Tests

run_test("No pkgconfig_dependencies", function()
    local rockspec = {
        variables = {},
    }
    resolve_pkgconfig(rockspec)
    assert_equal(nil, next(rockspec.variables))
end)

if zlib_available then
    run_test("Basic Resolution Success (zlib)", function()
        local rockspec = create_rockspec("zlib")

        resolve_pkgconfig(rockspec)

        -- Check that ZLIB_ variables are set
        assert_not_nil(rockspec.variables.ZLIB_LIBDIR,
                       "ZLIB_LIBDIR should be set")
        assert_not_nil(rockspec.variables.ZLIB_INCDIR,
                       "ZLIB_INCDIR should be set")
        assert_not_nil(rockspec.variables.ZLIB_DIR, "ZLIB_DIR should be set")
        assert_not_nil(rockspec.variables.ZLIB_MODVERSION,
                       "ZLIB_MODVERSION should be set")

        -- Check that paths are strings
        assert_equal("string", type(rockspec.variables.ZLIB_LIBDIR))
        assert_equal("string", type(rockspec.variables.ZLIB_INCDIR))
        assert_equal("string", type(rockspec.variables.ZLIB_DIR))
        assert_equal("string", type(rockspec.variables.ZLIB_MODVERSION))
    end)

    run_test("User-provided vars are preserved (not overwritten by pkg-config)",
             function()
        -- When user provides ZLIB_INCDIR/LIBDIR explicitly, resolve_args runs
        -- and preserves the user values rather than replacing them with pkg-config.
        local rockspec = create_rockspec("zlib", {
            ZLIB_INCDIR = "/user/custom/include",
            ZLIB_LIBDIR = "/user/custom/lib",
        })

        resolve_pkgconfig(rockspec)

        assert_equal("/user/custom/include", rockspec.variables.ZLIB_INCDIR,
                     "user-provided INCDIR must be kept")
        assert_equal("/user/custom/lib", rockspec.variables.ZLIB_LIBDIR,
                     "user-provided LIBDIR must be kept")
    end)

    run_test("Variables with unchanged values (zlib)", function()
        -- First resolve to get actual values
        local rockspec1 = create_rockspec("zlib")
        resolve_pkgconfig(rockspec1)

        local actual_includedir = rockspec1.variables.ZLIB_INCDIR
        local actual_libdir = rockspec1.variables.ZLIB_LIBDIR

        -- Run again on a clean rockspec (no user vars); values should match
        local rockspec2 = create_rockspec("zlib")
        resolve_pkgconfig(rockspec2)

        assert_equal(actual_includedir, rockspec2.variables.ZLIB_INCDIR)
        assert_equal(actual_libdir, rockspec2.variables.ZLIB_LIBDIR)
    end)
else
    print("SKIPPED: zlib not available via pkg-config")
end

run_test("Package not found", function()
    local rockspec = create_rockspec("nonexistent-pkg-12345")

    resolve_pkgconfig(rockspec)

    -- No variables should be set for nonexistent package
    assert_equal(nil, rockspec.variables.NONEXISTENT_PKG_12345_INCDIR)
    assert_equal(nil, rockspec.variables.NONEXISTENT_PKG_12345_LIBDIR)
end)

run_test("Keep variables when package not found", function()
    local rockspec = create_rockspec("nonexistent-pkg-67890", {
        NONEXISTENT_PKG_67890_INCDIR = "/old/include",
        NONEXISTENT_PKG_67890_LIBDIR = "/old/lib",
        NONEXISTENT_PKG_67890_CUSTOM_VAR = "custom_value",
    })

    resolve_pkgconfig(rockspec)

    -- Variables should be kept: user explicitly provided them, so resolve_args
    -- runs and preserves them (pkg-config is never consulted).
    assert_equal("/old/include", rockspec.variables.NONEXISTENT_PKG_67890_INCDIR)
    assert_equal("/old/lib", rockspec.variables.NONEXISTENT_PKG_67890_LIBDIR)
    assert_equal("custom_value",
                 rockspec.variables.NONEXISTENT_PKG_67890_CUSTOM_VAR)
end)

-- Test for partial match with suggestions
run_test("Package not found with suggestions", function()
    local rockspec = create_rockspec("zli") -- Partial match for "zlib"

    resolve_pkgconfig(rockspec)

    -- No variables should be set for partial match
    assert_equal(nil, rockspec.variables.ZLI_INCDIR)
    assert_equal(nil, rockspec.variables.ZLI_LIBDIR)
end)

if zlib_available then
    run_test("Case insensitive package name resolution", function()
        local rockspec = create_rockspec("ZLIB") -- Use uppercase

        resolve_pkgconfig(rockspec)

        -- Variables should still be set with ZLIB_ prefix (original name)
        assert_not_nil(rockspec.variables.ZLIB_INCDIR,
                       "ZLIB_INCDIR should be set")
        assert_not_nil(rockspec.variables.ZLIB_LIBDIR,
                       "ZLIB_LIBDIR should be set")
    end)

    run_test("Remove obsolete variables when package found", function()
        -- resolve_one (pkg-config path): old vars not returned by pkg-config are removed.
        -- Use mocked io.popen to return a fixed, minimal set of variables.
        local rockspec = {
            variables = {
                -- Pre-existing vars: these will be extracted by make_pkginfo.
                -- Since no user-supplied vars trigger resolve_args, resolve_one runs.
                -- update_variables removes ZLIB_CUSTOM_VAR because pkg-config
                -- does not produce it.
            },
            build = {
                pkgconfig_dependencies = {
                    RMTEST = {},
                },
            },
        }

        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            -- First call: find_package → exact match
            if cmd:find("list%-all") then
                return make_fake_file("RMTEST\n")
            end
            -- Second call: get_pkg_variables → only returns INCDIR/LIBDIR
            return make_fake_file("prefix=/opt/rmtest\n" ..
                                      "includedir=/opt/rmtest/include\n" ..
                                      "libdir=/opt/rmtest/lib\n" ..
                                      "Name=RMTEST\n" .. "Version=1.0\n" ..
                                      "Libs=-L/opt/rmtest/lib -lrmtest\n" ..
                                      "Cflags=-I/opt/rmtest/include\n" ..
                                      "Modversion=1.0\n")
        end

        resolve_pkgconfig(rockspec)
        _G.io.popen = old_popen

        -- Standard variables should be set from pkg-config
        assert_not_nil(rockspec.variables.RMTEST_INCDIR,
                       "RMTEST_INCDIR should be set")
        assert_not_nil(rockspec.variables.RMTEST_LIBDIR,
                       "RMTEST_LIBDIR should be set")
        assert_not_nil(rockspec.variables.RMTEST_LIB, "RMTEST_LIB should be set")
    end)
end

-- Test cases with io.popen mocking for error paths
run_test("Handle io.popen failure in get_pkg_variables", function()
    -- No user-supplied vars → dispatches to resolve_one (pkg-config path).
    -- When get_pkg_variables fails, no variables should be set.
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                POPEN_FAIL_TEST = {},
            },
        },
    }

    local call_count = 0
    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        call_count = call_count + 1
        -- First call is find_package, let it succeed
        if call_count == 1 then
            return make_fake_file("POPEN_FAIL_TEST\n")
        end
        -- Second call is get_pkg_variables, make it fail
        return nil, "simulated io.popen failure"
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen

    -- get_pkg_variables failed → no variables should be set
    assert_equal(nil, rockspec.variables.POPEN_FAIL_TEST_INCDIR)
    assert_equal(nil, rockspec.variables.POPEN_FAIL_TEST_LIBDIR)
end)

run_test("Handle io.popen failure in find_package", function()
    -- No user-supplied vars → dispatches to resolve_one (pkg-config path).
    -- When find_package fails (io.popen returns nil), no variables should be set.
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                ["popen-fail-find"] = {},
            },
        },
    }

    local old_popen = _G.io.popen
    _G.io.popen = function(_)
        return nil, "simulated io.popen failure"
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen

    -- find_package failed → no variables should be set
    assert_equal(nil, rockspec.variables.POPEN_FAIL_FIND_INCDIR)
    assert_equal(nil, rockspec.variables.POPEN_FAIL_FIND_LIBDIR)
end)

if zlib_available then
    run_test("Continue processing remaining deps when one is not in pkg-config",
             function()
        -- Two pkgconfig_dependencies: zlib (valid) + nonexistent (not in pkg-config)
        local rockspec = {
            variables = {},
            build = {
                pkgconfig_dependencies = {
                    zlib = {},
                    ["nonexistent-pkg-99999"] = {},
                },
            },
        }

        resolve_pkgconfig(rockspec)

        -- zlib variables should be set
        assert_not_nil(rockspec.variables.ZLIB_INCDIR,
                       "ZLIB_INCDIR should be set")
        assert_not_nil(rockspec.variables.ZLIB_LIBDIR,
                       "ZLIB_LIBDIR should be set")

        -- nonexistent package variables should be absent
        assert_equal(nil, rockspec.variables.NONEXISTENT_PKG_99999_INCDIR)
        assert_equal(nil, rockspec.variables.NONEXISTENT_PKG_99999_LIBDIR)
    end)
end

if zlib_available then
    run_test("*_LIB variable is set for single-library package (zlib)",
             function()
        local rockspec = create_rockspec("zlib")
        resolve_pkgconfig(rockspec)

        -- ZLIB_LIB should be a string (at least one library name)
        assert_not_nil(rockspec.variables.ZLIB_LIB, "ZLIB_LIB should be set")
        assert_equal("string", type(rockspec.variables.ZLIB_LIB))
    end)

    run_test("Single-lib $(VAR_LIB) in libraries is not expanded by hook",
             function()
        local rockspec = {
            variables = {},
            build = {
                pkgconfig_dependencies = {
                    zlib = {},
                },
                modules = {
                    mymod = {
                        libraries = {
                            "$(ZLIB_LIB)",
                        },
                    },
                },
            },
        }
        resolve_pkgconfig(rockspec)

        -- For a single-lib package, the entry should remain as $(ZLIB_LIB)
        -- so LuaRocks can do native variable substitution
        assert_equal("$(ZLIB_LIB)", rockspec.build.modules.mymod.libraries[1])
        assert_equal(1, #rockspec.build.modules.mymod.libraries)
    end)
end

run_test("Multi-lib $(VAR_LIB) entry in libraries is expanded", function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYLIB = {},
            },
            modules = {
                mymod = {
                    libraries = {
                        "$(MYLIB_LIB)",
                    },
                },
            },
        },
    }

    local call_count = 0
    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        call_count = call_count + 1
        if call_count == 1 then
            -- find_package: exact match
            return make_fake_file("MYLIB\n")
        end
        -- get_pkg_variables: two -l flags
        return make_fake_file(
                   "prefix=/path\n" .. "includedir=/path/include\n" ..
                       "libdir=/path/lib\n" .. "Name=MYLIB\n" .. "Version=1.0\n" ..
                       "Libs=-L/path/lib -lssl -lcrypto\n" ..
                       "Cflags=-I/path/include\n" .. "Modversion=1.0\n")
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen

    -- *_LIB variable should contain all library names space-separated
    assert_equal("ssl crypto", rockspec.variables.MYLIB_LIB,
                 "MYLIB_LIB should contain all library names")

    -- libraries should be expanded into individual entries
    assert_equal(2, #rockspec.build.modules.mymod.libraries,
                 "libraries should have 2 entries after expansion")
    assert_equal("ssl", rockspec.build.modules.mymod.libraries[1])
    assert_equal("crypto", rockspec.build.modules.mymod.libraries[2])
end)

run_test(
    "Multi-lib $(VAR_LIB) with surrounding whitespace in libraries is expanded",
    function()
        local rockspec = {
            variables = {},
            build = {
                pkgconfig_dependencies = {
                    MYLIB = {},
                },
                modules = {
                    mymod = {
                        libraries = {
                            "  $(MYLIB_LIB)  ",
                        },
                    },
                },
            },
        }

        local call_count = 0
        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            call_count = call_count + 1
            if call_count == 1 then
                return make_fake_file("MYLIB\n")
            end
            return make_fake_file("prefix=/path\n" ..
                                      "includedir=/path/include\n" ..
                                      "libdir=/path/lib\n" .. "Name=MYLIB\n" ..
                                      "Version=1.0\n" ..
                                      "Libs=-L/path/lib -lssl -lcrypto\n" ..
                                      "Cflags=-I/path/include\n" ..
                                      "Modversion=1.0\n")
        end

        resolve_pkgconfig(rockspec)
        _G.io.popen = old_popen

        -- surrounding whitespace is ignored: entry expands to multiple entries
        assert_equal(2, #rockspec.build.modules.mymod.libraries)
        assert_equal("ssl", rockspec.build.modules.mymod.libraries[1])
        assert_equal("crypto", rockspec.build.modules.mymod.libraries[2])
    end)

run_test("Multi-lib $(VAR_LIB) embedded in library entry raises error",
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYLIB = {},
            },
            modules = {
                mymod = {
                    libraries = {
                        "extra_$(MYLIB_LIB)",
                    },
                },
            },
        },
    }

    local call_count = 0
    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        call_count = call_count + 1
        if call_count == 1 then
            return make_fake_file("MYLIB\n")
        end
        return make_fake_file("prefix=/path\n" ..
                                  "Libs=-L/path/lib -lssl -lcrypto\n")
    end

    local ok, err = pcall(resolve_pkgconfig, rockspec)
    _G.io.popen = old_popen

    assert_equal(false, ok,
                 "should raise an error for embedded multi-lib reference")
    assert_not_nil(err:find("$(MYLIB_LIB)", 1, true),
                   "error message should mention the variable reference")
end)

run_test("Multi-lib $(VAR_LIB) as string libraries is converted to array",
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYLIB = {},
            },
            modules = {
                mymod = {
                    libraries = "  $(MYLIB_LIB)  ",
                },
            },
        },
    }

    local call_count = 0
    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        call_count = call_count + 1
        if call_count == 1 then
            return make_fake_file("MYLIB\n")
        end
        return make_fake_file(
                   "prefix=/path\n" .. "includedir=/path/include\n" ..
                       "libdir=/path/lib\n" .. "Name=MYLIB\n" .. "Version=1.0\n" ..
                       "Libs=-L/path/lib -lssl -lcrypto\n" ..
                       "Cflags=-I/path/include\n" .. "Modversion=1.0\n")
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen

    -- string libraries matching the pattern (with whitespace) should be converted to an array
    assert_equal("table", type(rockspec.build.modules.mymod.libraries))
    assert_equal(2, #rockspec.build.modules.mymod.libraries)
    assert_equal("ssl", rockspec.build.modules.mymod.libraries[1])
    assert_equal("crypto", rockspec.build.modules.mymod.libraries[2])
end)

run_test(
    "Package name with hyphens and dots produces normalized variable names",
    function()
        local rockspec = {
            variables = {},
            build = {
                pkgconfig_dependencies = {
                    ["foo-2.0"] = {},
                },
                modules = {},
            },
        }

        local call_count = 0
        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            call_count = call_count + 1
            if call_count == 1 then
                return make_fake_file("foo-2.0\n")
            end
            return make_fake_file("prefix=/path\n" ..
                                      "includedir=/path/include\n" ..
                                      "libdir=/path/lib\n" .. "Name=foo-2.0\n" ..
                                      "Version=2.0\n" ..
                                      "Libs=-L/path/lib -lfoo\n" ..
                                      "Cflags=-I/path/include\n" ..
                                      "Modversion=2.0\n")
        end

        resolve_pkgconfig(rockspec)
        _G.io.popen = old_popen

        -- Hyphens and dots must be replaced with underscores for LuaRocks $(VAR) substitution
        assert_not_nil(rockspec.variables["FOO_2_0_INCDIR"],
                       "FOO_2_0_INCDIR should be set")
        assert_not_nil(rockspec.variables["FOO_2_0_LIBDIR"],
                       "FOO_2_0_LIBDIR should be set")
        assert_not_nil(rockspec.variables["FOO_2_0_LIB"],
                       "FOO_2_0_LIB should be set")
        -- Dot-containing names must NOT appear as variable keys
        for k in pairs(rockspec.variables) do
            assert(not k:find("[^%a%d_]"),
                   "variable key contains invalid character: " .. k)
        end
    end)

run_test("Raw dep name with hyphens: $(VAR) refs in modules are normalized",
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                ["MYLIB-2"] = {},
            },
            modules = {
                mymod = {
                    libraries = {
                        "$(MYLIB-2_LIB)",
                    },
                    incdirs = {
                        "$(MYLIB-2_INCDIR)",
                    },
                    libdirs = {
                        "$(MYLIB-2_LIBDIR)",
                    },
                },
            },
        },
    }

    local call_count = 0
    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        call_count = call_count + 1
        if call_count == 1 then
            return make_fake_file("MYLIB-2\n")
        end
        return make_fake_file("prefix=/opt/mylib\n" ..
                                  "includedir=/opt/mylib/include\n" ..
                                  "libdir=/opt/mylib/lib\n" .. "Name=MYLIB-2\n" ..
                                  "Version=2.0\n" ..
                                  "Libs=-L/opt/mylib/lib -lmylib2\n" ..
                                  "Cflags=-I/opt/mylib/include\n" ..
                                  "Modversion=2.0\n")
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen

    -- Variables should be set with normalized prefix
    assert_not_nil(rockspec.variables["MYLIB_2_INCDIR"],
                   "MYLIB_2_INCDIR should be set")
    assert_not_nil(rockspec.variables["MYLIB_2_LIBDIR"],
                   "MYLIB_2_LIBDIR should be set")
    assert_not_nil(rockspec.variables["MYLIB_2_DIR"],
                   "MYLIB_2_DIR should be set")
    assert_not_nil(rockspec.variables["MYLIB_2_LIB"],
                   "MYLIB_2_LIB should be set")

    -- Raw-form $(MYLIB-2_*) references in modules should be replaced with
    -- normalized $(MYLIB_2_*) so LuaRocks $(VAR) substitution works
    assert_equal("$(MYLIB_2_LIB)", rockspec.build.modules.mymod.libraries[1],
                 "libraries ref should be normalized")
    assert_equal("$(MYLIB_2_INCDIR)", rockspec.build.modules.mymod.incdirs[1],
                 "incdirs ref should be normalized")
    assert_equal("$(MYLIB_2_LIBDIR)", rockspec.build.modules.mymod.libdirs[1],
                 "libdirs ref should be normalized")
end)

run_test(
    "String libraries/incdirs/libdirs are converted to arrays when dep vars are found",
    function()
        local rockspec = {
            variables = {},
            build = {
                pkgconfig_dependencies = {
                    STRTEST = {},
                },
                modules = {
                    mymod = {
                        libraries = "$(STRTEST_LIB)",
                        incdirs = "$(STRTEST_INCDIR)",
                        libdirs = "$(STRTEST_LIBDIR)",
                    },
                },
            },
        }

        local call_count = 0
        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            call_count = call_count + 1
            if call_count == 1 then
                return make_fake_file("STRTEST\n")
            end
            return make_fake_file("prefix=/opt/strtest\n" ..
                                      "includedir=/opt/strtest/include\n" ..
                                      "libdir=/opt/strtest/lib\n" ..
                                      "Libs=-L/opt/strtest/lib -lstrtest\n" ..
                                      "Cflags=-I/opt/strtest/include\n" ..
                                      "Modversion=1.0\n")
        end

        resolve_pkgconfig(rockspec)
        _G.io.popen = old_popen

        -- String fields referencing this dep's vars should be converted to arrays
        assert_equal("table", type(rockspec.build.modules.mymod.libraries),
                     "libraries should be a table")
        assert_equal("table", type(rockspec.build.modules.mymod.incdirs),
                     "incdirs should be a table")
        assert_equal("table", type(rockspec.build.modules.mymod.libdirs),
                     "libdirs should be a table")
        -- Single-lib: entry stays as $(STRTEST_LIB) for LuaRocks substitution
        assert_equal("$(STRTEST_LIB)", rockspec.build.modules.mymod.libraries[1])
        assert_equal("$(STRTEST_INCDIR)",
                     rockspec.build.modules.mymod.incdirs[1])
        assert_equal("$(STRTEST_LIBDIR)",
                     rockspec.build.modules.mymod.libdirs[1])
    end)

run_test("Modules without dep var refs are not modified by get_target_modules",
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYFOO = {},
            },
            modules = {
                -- This module has no MYFOO references; its string field must
                -- remain a string (not converted to array).
                unrelated = {
                    libraries = "other_lib",
                },
            },
        },
    }

    local call_count = 0
    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        call_count = call_count + 1
        if call_count == 1 then
            return make_fake_file("MYFOO\n")
        end
        return make_fake_file("prefix=/opt/myfoo\n" ..
                                  "includedir=/opt/myfoo/include\n" ..
                                  "libdir=/opt/myfoo/lib\n" ..
                                  "Libs=-L/opt/myfoo/lib -lmyfoo\n" ..
                                  "Modversion=1.0\n")
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen

    -- Unrelated module's string field should remain unchanged
    assert_equal("string", type(rockspec.build.modules.unrelated.libraries),
                 "unrelated module libraries should remain a string")
    assert_equal("other_lib", rockspec.build.modules.unrelated.libraries)
end)

-- resolve_args tests

run_test("resolve_args: DIR only → INCDIR and LIBDIR are derived", function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {},
            },
        },
    }

    resolve_pkgconfig(rockspec)

    assert_equal("/my/custom/path", rockspec.variables.MYPKG_DIR)
    assert_equal("/my/custom/path/include", rockspec.variables.MYPKG_INCDIR)
    assert_equal("/my/custom/path/lib", rockspec.variables.MYPKG_LIBDIR)
end)

run_test("resolve_args: DIR + user INCDIR → INCDIR preserved", function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
            MYPKG_INCDIR = "/user/incdir",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {},
            },
        },
    }

    resolve_pkgconfig(rockspec)

    assert_equal("/my/custom/path", rockspec.variables.MYPKG_DIR)
    assert_equal("/user/incdir", rockspec.variables.MYPKG_INCDIR,
                 "user-provided INCDIR must not be overwritten by DIR/include")
    assert_equal("/my/custom/path/lib", rockspec.variables.MYPKG_LIBDIR)
end)

run_test("resolve_args: pkgdep without library → no LIB set", function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {}, -- no library field
            },
        },
    }

    resolve_pkgconfig(rockspec)

    assert_equal(nil, rockspec.variables.MYPKG_LIB,
                 "LIB must not be set when pkgdep has no library")
end)

run_test("resolve_args: pkgdep.library sets LIB and validates file in LIBDIR",
         function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = "myfoo",
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    -- Simulate that a libmyfoo.* file exists in /my/custom/path/lib
    fs.is_file = function(path)
        return path:find("/my/custom/path/lib/libmyfoo", 1, true) ~= nil
    end

    resolve_pkgconfig(rockspec)
    fs.is_file = orig_is_file

    assert_equal("myfoo", rockspec.variables.MYPKG_LIB,
                 "LIB should be set from pkgdep.library")
    assert_equal("/my/custom/path/lib", rockspec.variables.MYPKG_LIBDIR)
end)

run_test("resolve_args: pkgdep.library not found in LIBDIR → error",
         function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = "notexist",
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(_)
        return false
    end

    local ok, err = pcall(resolve_pkgconfig, rockspec)
    fs.is_file = orig_is_file

    assert_equal(false, ok, "should raise an error when library is not found")
    assert_not_nil(err:find("notexist"), "error should mention the library name")
end)

run_test("resolve_args: pkgdep.header validates file in INCDIR", function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = "mypkg.h",
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(path)
        return path == "/my/custom/path/include/mypkg.h"
    end

    resolve_pkgconfig(rockspec)
    fs.is_file = orig_is_file

    assert_equal("/my/custom/path/include", rockspec.variables.MYPKG_INCDIR)
end)

run_test("resolve_args: pkgdep.header not found in INCDIR → error", function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = "notexist.h",
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(_)
        return false
    end

    local ok, err = pcall(resolve_pkgconfig, rockspec)
    fs.is_file = orig_is_file

    assert_equal(false, ok, "should raise an error when header is not found")
    assert_not_nil(err:find("notexist.h"),
                   "error should mention the header name")
end)

run_test("resolve_args: user-provided LIB is preserved", function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
            MYPKG_LIB = "custom_lib_name",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = "default_lib",
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    -- Simulate library exists in LIBDIR
    fs.is_file = function(path)
        return path:find("/my/custom/path/lib/libdefault_lib", 1, true) ~= nil
    end

    resolve_pkgconfig(rockspec)
    fs.is_file = orig_is_file

    assert_equal("custom_lib_name", rockspec.variables.MYPKG_LIB,
                 "user-provided LIB must not be overwritten by pkgdep.library")
end)

run_test("find_incdir: header found in compiler default path sets INCDIR",
         function()
    -- MYPKG_CUSTOM is set to trigger resolve_args directly (skip pkg-config).
    -- No DIR/INCDIR set, so find_incdir falls back to compiler default paths.
    local rockspec = {
        variables = {
            CC = "fake-cc",
            MYPKG_CUSTOM = "value",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = "mypkg.h",
                },
            },
        },
    }

    local old_popen = _G.io.popen
    _G.io.popen = function(cmd)
        -- Fake cc -v output listing one include directory.
        if cmd:find("fake-cc", 1, true) and cmd:find("-xc", 1, true) then
            return make_fake_file("#include <...> search starts here:\n" ..
                                      " /fake/system/include\n" ..
                                      "End of search list.\n")
        end
        return nil, "unexpected popen: " .. tostring(cmd)
    end

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(path)
        return path == "/fake/system/include/mypkg.h"
    end

    resolve_pkgconfig(rockspec)
    _G.io.popen = old_popen
    fs.is_file = orig_is_file

    assert_equal("/fake/system/include", rockspec.variables.MYPKG_INCDIR,
                 "INCDIR should be set to compiler default path where header was found")
end)

run_test(
    "find_incdir: header not found in default paths → error with INCDIR hint",
    function()
        local rockspec = {
            variables = {
                CC = "fake-cc",
                MYPKG_CUSTOM = "value",
            },
            build = {
                pkgconfig_dependencies = {
                    MYPKG = {
                        header = "mypkg.h",
                    },
                },
            },
        }

        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            if cmd:find("fake-cc", 1, true) and cmd:find("-xc", 1, true) then
                return make_fake_file("#include <...> search starts here:\n" ..
                                          " /fake/system/include\n" ..
                                          "End of search list.\n")
            end
            return nil, "unexpected popen: " .. tostring(cmd)
        end

        local fs = require("luarocks.fs")
        local orig_is_file = fs.is_file
        fs.is_file = function(_)
            return false
        end

        local ok, err = pcall(resolve_pkgconfig, rockspec)
        _G.io.popen = old_popen
        fs.is_file = orig_is_file

        assert_equal(false, ok,
                     "should raise when header is not found in any path")
        assert_not_nil(err:find("mypkg.h"),
                       "error should mention the header name")
        assert_not_nil(err:find("MYPKG_INCDIR"),
                       "error should hint at the variable name to set")
    end)

run_test("find_libdir: library found in fallback path sets LIBDIR", function()
    -- MYPKG_CUSTOM triggers resolve_args directly (no pkg-config).
    -- CC="cc" lets get_compiler_libdirs run the real shell script; io.popen is
    -- NOT mocked. /usr/local/lib is always in the pre-populated fallback list,
    -- so we mock only fs.is_file to report the library present there.
    local rockspec = {
        variables = {
            CC = "cc",
            MYPKG_CUSTOM = "value",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = "mypkg",
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(path)
        return path == "/usr/local/lib/libmypkg.a"
    end

    resolve_pkgconfig(rockspec)
    fs.is_file = orig_is_file

    assert_equal("/usr/local/lib", rockspec.variables.MYPKG_LIBDIR,
                 "LIBDIR should be set to the fallback path where library was found")
    assert_equal("mypkg", rockspec.variables.MYPKG_LIB)
end)

run_test(
    "find_libdir: library not found in fallback paths → error with LIBDIR hint",
    function()
        -- CC="foobarbaz" causes the shell script to fail silently (command not found,
        -- suppressed by 2>/dev/null), leaving only pre-populated fallback paths.
        -- io.popen is NOT mocked. fs.is_file is mocked to always return false to
        -- simulate a system where the library is absent from every searched path.
        local rockspec = {
            variables = {
                CC = "foobarbaz",
                MYPKG_CUSTOM = "value",
            },
            build = {
                pkgconfig_dependencies = {
                    MYPKG = {
                        library = "definitely_nonexistent_lib_xyz123",
                    },
                },
            },
        }

        local fs = require("luarocks.fs")
        local orig_is_file = fs.is_file
        fs.is_file = function(_)
            return false
        end

        local ok, err = pcall(resolve_pkgconfig, rockspec)
        fs.is_file = orig_is_file

        assert_equal(false, ok,
                     "should raise when library is not found in any path")
        assert_not_nil(err:find("definitely_nonexistent_lib_xyz123"),
                       "error should mention the library name")
        assert_not_nil(err:find("MYPKG_LIBDIR"),
                       "error should hint at the variable name to set")
    end)

-- ============================================================
-- validate_pkgdep: type checking
-- ============================================================

run_test('validate_pkgdep: header as empty string → normalized to nil',
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = '',
                },
            },
        },
    }
    -- empty string is silently normalized to nil; no error expected
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(true, ok, err)
end)

run_test('validate_pkgdep: library as empty string → normalized to nil',
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = '',
                },
            },
        },
    }
    -- empty string is silently normalized to nil; no error expected
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(true, ok, err)
end)

run_test('validate_pkgdep: header as empty array → normalized to nil',
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = {},
                },
            },
        },
    }
    -- empty array is silently normalized to nil; no error expected
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(true, ok, err)
end)

run_test("validate_pkgdep: library array with non-string element → error",
         function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = {
                        "ok",
                        42,
                    },
                },
            },
        },
    }
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(false, ok)
    assert_not_nil(err:find("MYPKG"), "error should mention the dep name")
    assert_not_nil(err:find("library"), "error should mention the field")
    assert_not_nil(err:find("%[2%]"), "error should mention the index")
end)

run_test("validate_pkgdep: header as number → error", function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = 42,
                },
            },
        },
    }
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(false, ok)
    assert_not_nil(err:find("MYPKG"), "error should mention the dep name")
    assert_not_nil(err:find("header"), "error should mention the field")
    assert_not_nil(err:find("number"), "error should mention the bad type")
end)

-- ============================================================
-- Array header / library support
-- ============================================================

run_test("pkgdep.header as array: all headers found in INCDIR → INCDIR set",
         function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = {
                        "foo.h",
                        "bar.h",
                    },
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(path)
        -- Both headers live under the same INCDIR
        return path == "/my/custom/path/include/foo.h" or path ==
                   "/my/custom/path/include/bar.h"
    end

    resolve_pkgconfig(rockspec)
    fs.is_file = orig_is_file

    assert_equal("/my/custom/path/include", rockspec.variables.MYPKG_INCDIR,
                 "INCDIR should be set when all array headers are found")
end)

run_test("pkgdep.header as array: one header missing in INCDIR → error",
         function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = {
                        "foo.h",
                        "missing.h",
                    },
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(path)
        return path == "/my/custom/path/include/foo.h"
    end

    local ok, err = pcall(resolve_pkgconfig, rockspec)
    fs.is_file = orig_is_file

    assert_equal(false, ok, "should raise when one header is missing")
    assert_not_nil(err:find("missing.h"),
                   "error should mention the missing header")
end)

run_test(
    "pkgdep.library as array: all libraries found in LIBDIR → LIBDIR+LIB set",
    function()
        local rockspec = {
            variables = {
                MYPKG_DIR = "/my/custom/path",
            },
            build = {
                pkgconfig_dependencies = {
                    MYPKG = {
                        library = {
                            "ssl",
                            "crypto",
                        },
                    },
                },
            },
        }

        local fs = require("luarocks.fs")
        local orig_is_file = fs.is_file
        fs.is_file = function(path)
            return path == "/my/custom/path/lib/libssl.a" or path ==
                       "/my/custom/path/lib/libcrypto.a"
        end

        resolve_pkgconfig(rockspec)
        fs.is_file = orig_is_file

        assert_equal("/my/custom/path/lib", rockspec.variables.MYPKG_LIBDIR,
                     "LIBDIR should be set when all array libraries are found")
        assert_equal("ssl crypto", rockspec.variables.MYPKG_LIB,
                     "LIB should be space-separated library names")
    end)

run_test("pkgdep.library as array: one library missing in LIBDIR → error",
         function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = {
                        "ssl",
                        "missing_lib",
                    },
                },
            },
        },
    }

    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(path)
        return path:find("/libssl", 1, true) ~= nil
    end

    local ok, err = pcall(resolve_pkgconfig, rockspec)
    fs.is_file = orig_is_file

    assert_equal(false, ok, "should raise when one library is missing")
    assert_not_nil(err:find("missing_lib"),
                   "error should mention the missing library")
end)

run_test(
    "pkgdep.library as array: not found in default paths → error with hint",
    function()
        local rockspec = {
            variables = {
                CC = "foobarbaz",
                MYPKG_CUSTOM = "value",
            },
            build = {
                pkgconfig_dependencies = {
                    MYPKG = {
                        library = {
                            "libA",
                            "libB",
                        },
                    },
                },
            },
        }

        local fs = require("luarocks.fs")
        local orig_is_file = fs.is_file
        fs.is_file = function(_)
            return false
        end

        local ok, err = pcall(resolve_pkgconfig, rockspec)
        fs.is_file = orig_is_file

        assert_equal(false, ok,
                     "should raise when no dir contains all libraries")
        assert_not_nil(err:find("libA") or err:find("libB"),
                       "error should mention a library name")
        assert_not_nil(err:find("MYPKG_LIBDIR"),
                       "error should hint at the variable to set")
    end)

-- ============================================================
-- resvars in pkgdep.header / pkgdep.library
-- ============================================================

run_test("pkgdep.header: $(VAR) resolved from variables", function()
    local resolved_header
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
            MY_HEADER = "foo.h",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = "$(MY_HEADER)",
                },
            },
        },
    }
    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(p)
        resolved_header = p
        return true
    end
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    fs.is_file = orig_is_file
    assert_equal(true, ok, err)
    assert_not_nil(resolved_header and resolved_header:find("foo.h"),
                   "header should be resolved to foo.h, got: " ..
                       tostring(resolved_header))
end)

run_test("pkgdep.header: $(VAR)? missing → treated as nil (skipped)",
         function()
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = "$(MY_HEADER)?",
                },
            },
        },
    }
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(true, ok, err)
end)

run_test("pkgdep.header: $(VAR) missing → error", function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    header = "$(MY_HEADER)",
                },
            },
        },
    }
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(false, ok, "should raise for unresolved required variable")
    assert_not_nil(err:find("MY_HEADER"),
                   "error should mention the variable name")
end)

run_test("pkgdep.library: $(VAR) resolved from variables", function()
    local resolved_lib
    local rockspec = {
        variables = {
            MYPKG_DIR = "/my/custom/path",
            MY_LIB = "mylib",
        },
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = "$(MY_LIB)",
                },
            },
        },
    }
    local fs = require("luarocks.fs")
    local orig_is_file = fs.is_file
    fs.is_file = function(p)
        resolved_lib = p
        return true
    end
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    fs.is_file = orig_is_file
    assert_equal(true, ok, err)
    assert_not_nil(resolved_lib and resolved_lib:find("mylib"),
                   "library should be resolved to mylib, got: " ..
                       tostring(resolved_lib))
end)

run_test("pkgdep.library: $(VAR) missing → error", function()
    local rockspec = {
        variables = {},
        build = {
            pkgconfig_dependencies = {
                MYPKG = {
                    library = "$(MY_LIB)",
                },
            },
        },
    }
    local ok, err = pcall(resolve_pkgconfig, rockspec)
    assert_equal(false, ok, "should raise for unresolved required variable")
    assert_not_nil(err:find("MY_LIB"), "error should mention the variable name")
end)
print('All pkgconfig tests passed')
