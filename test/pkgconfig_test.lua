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

local function assert_not_equal(expected, actual, msg)
    if expected == actual then
        error((msg or "") .. " Expected " .. tostring(actual) ..
                  " to be different from " .. tostring(expected))
    end
end

-- Helper function to create a basic rockspec with external_dependencies
local function create_rockspec(pkg, variables)
    return {
        external_dependencies = {
            [pkg] = {},
        },
        variables = variables or {},
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

-- Tests

run_test("No external_dependencies", function()
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

    run_test("Update existing variables (zlib)", function()
        local rockspec = create_rockspec("zlib", {
            ZLIB_INCDIR = "/old/include",
            ZLIB_LIBDIR = "/old/lib",
        })

        resolve_pkgconfig(rockspec)

        -- Check that old values were replaced
        assert_not_equal("/old/include", rockspec.variables.ZLIB_INCDIR)
        assert_not_equal("/old/lib", rockspec.variables.ZLIB_LIBDIR)
    end)

    run_test("Variables with unchanged values (zlib)", function()
        -- First resolve to get actual values
        local rockspec1 = create_rockspec("zlib")
        resolve_pkgconfig(rockspec1)

        local actual_includedir = rockspec1.variables.ZLIB_INCDIR
        local actual_libdir = rockspec1.variables.ZLIB_LIBDIR

        -- Now test with unchanged values
        local rockspec2 = create_rockspec("zlib", {
            ZLIB_INCDIR = actual_includedir,
            ZLIB_LIBDIR = actual_libdir,
        })

        resolve_pkgconfig(rockspec2)

        -- Values should remain the same
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

    -- Variables should be kept since package doesn't exist (early return)
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
        -- First, get the current pkg-config variables
        local rockspec1 = create_rockspec("zlib")
        resolve_pkgconfig(rockspec1)

        -- Get all ZLIB_ variables
        local zlib_vars = {}
        for k, v in pairs(rockspec1.variables) do
            if k:match("^ZLIB_") then
                zlib_vars[k] = v
            end
        end

        -- Create a new rockspec with current variables plus a custom variable
        local rockspec2 = create_rockspec("zlib")
        for k, v in pairs(zlib_vars) do
            rockspec2.variables[k] = v
        end
        -- Add a custom variable that won't be in the new pkg-config output
        rockspec2.variables.ZLIB_CUSTOM_VAR = "custom_value"

        resolve_pkgconfig(rockspec2)

        -- Custom variable should be removed
        assert_equal(nil, rockspec2.variables.ZLIB_CUSTOM_VAR,
                     "ZLIB_CUSTOM_VAR should be removed")

        -- Standard variables should still exist
        assert_not_nil(rockspec2.variables.ZLIB_INCDIR,
                       "ZLIB_INCDIR should be set")
        assert_not_nil(rockspec2.variables.ZLIB_LIBDIR,
                       "ZLIB_LIBDIR should be set")
    end)
end

-- Test cases with io.popen mocking for error paths
if zlib_available then
    run_test("Handle io.popen failure in get_pkg_variables", function()
        local rockspec = create_rockspec("zlib", {
            ZLIB_INCDIR = "/existing/include",
            ZLIB_LIBDIR = "/existing/lib",
            ZLIB_CUSTOM_VAR = "custom_value",
        })

        -- Mock io.popen to fail only for get_pkg_variables (second call)
        -- find_package (first call) should succeed
        local call_count = 0
        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            call_count = call_count + 1
            -- First call is find_package, let it succeed
            if call_count == 1 then
                return old_popen(cmd)
            end
            -- Second call is get_pkg_variables, make it fail
            return nil, "simulated io.popen failure"
        end

        resolve_pkgconfig(rockspec)

        -- Restore original io.popen
        _G.io.popen = old_popen

        -- make_pkginfo extracts ZLIB_* vars from rockspec.variables upfront (raw
        -- prefix "ZLIB_" == normalized prefix for a non-hyphenated name).
        -- When get_pkg_variables then fails, the extracted vars are not restored
        -- and the build would fail for missing variables anyway.
        assert_equal(nil, rockspec.variables.ZLIB_INCDIR)
        assert_equal(nil, rockspec.variables.ZLIB_LIBDIR)
        assert_equal(nil, rockspec.variables.ZLIB_CUSTOM_VAR)
    end)

    run_test("Handle io.popen failure in find_package", function()
        local rockspec = create_rockspec("zlib-nonexist", {
            ZLIB_NONEXIST_INCDIR = "/existing/include",
        })

        -- Mock io.popen to fail only for find_package
        local call_count = 0
        local old_popen = _G.io.popen
        _G.io.popen = function(cmd)
            call_count = call_count + 1
            -- First call is find_package, make it fail
            if call_count == 1 then
                return nil, "simulated io.popen failure"
            end
            -- Subsequent calls use original
            return old_popen(cmd)
        end

        resolve_pkgconfig(rockspec)

        -- Restore original io.popen
        _G.io.popen = old_popen

        -- Variables should remain unchanged since find_package failed
        assert_equal("/existing/include",
                     rockspec.variables.ZLIB_NONEXIST_INCDIR)
    end)
end

if zlib_available then
    run_test("Continue processing remaining deps when one is not in pkg-config",
             function()
        -- Two external_dependencies: zlib (valid) + nonexistent (not in pkg-config)
        local rockspec = {
            external_dependencies = {
                zlib = {},
                ["nonexistent-pkg-99999"] = {},
            },
            variables = {},
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
            external_dependencies = {
                zlib = {},
            },
            variables = {},
            build = {
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

run_test("Multi-lib $(VAR_LIB) entry in libraries is expanded", function()
    local rockspec = {
        external_dependencies = {
            MYLIB = {},
        },
        variables = {},
        build = {
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
            external_dependencies = {
                MYLIB = {},
            },
            variables = {},
            build = {
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
        external_dependencies = {
            MYLIB = {},
        },
        variables = {},
        build = {
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
        external_dependencies = {
            MYLIB = {},
        },
        variables = {},
        build = {
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
            external_dependencies = {
                ["foo-2.0"] = {},
            },
            variables = {},
            build = {
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
        external_dependencies = {
            ["MYLIB-2"] = {},
        },
        variables = {},
        build = {
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
            external_dependencies = {
                STRTEST = {},
            },
            variables = {},
            build = {
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
        external_dependencies = {
            MYFOO = {},
        },
        variables = {},
        build = {
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

print("All pkgconfig tests passed!")
