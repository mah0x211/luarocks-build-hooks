require("luacov")

-- Mock pkginfo dependency
local mock_pkginfo = {
    result = nil, -- pkginfo table or nil
    err = nil,
}
mock_pkginfo.reset = function()
    mock_pkginfo.result = nil
    mock_pkginfo.err = nil
    mock_pkginfo.constraints = nil
end
package.loaded["luarocks.build.hooks.lib.pkginfo"] = function(pkgname,
                                                              constraints)
    mock_pkginfo.pkgname = pkgname
    mock_pkginfo.constraints = constraints
    return mock_pkginfo.result, mock_pkginfo.err
end

-- Load module under test
local incdirs = require("luarocks.build.hooks.lib.incdirs")

-- Test helpers

local function run_test(name, func)
    io.write("Running " .. name .. "... ")
    mock_pkginfo.reset()
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

-- ── pkginfo returns nil ─────────────────────────────────────────────────────

run_test("Returns nil when package not found", function()
    mock_pkginfo.result = nil
    mock_pkginfo.err = nil
    local result, err = incdirs("nonexistent")
    assert_nil(result)
    assert_nil(err)
end)

-- ── pkginfo returns nil with error ──────────────────────────────────────────

run_test("Returns nil with error when pkginfo fails", function()
    mock_pkginfo.result = nil
    mock_pkginfo.err = "load failed"
    local result, err = incdirs("mylib")
    assert_nil(result)
    assert_equal("load failed", err)
end)

-- ── manifest has no conf section ────────────────────────────────────────────

run_test("Returns nil when manifest has no conf section", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {},
    }
    local result = incdirs("mylib")
    assert_nil(result)
end)

-- ── conf section has no .h files ────────────────────────────────────────────

run_test("Returns nil when conf section has no .h files", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {
            conf = {
                ["readme.txt"] = true,
                ["Makefile"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_nil(result)
end)

-- ── .h file at root of conf directory ───────────────────────────────────────

run_test("Returns conf dir and header for root-level .h file", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {
            conf = {
                ["mylib.h"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_not_nil(result)
    assert_equal(1, #result.incdirs)
    assert_equal("/mock/conf", result.incdirs[1])
    assert_equal(1, #result.headers)
    assert_equal("mylib.h", result.headers[1])
end)

-- ── .h file in subdirectory ─────────────────────────────────────────────────

run_test("Returns subdir path and header for nested .h file", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {
            conf = {
                ["mylib/core.h"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_not_nil(result)
    assert_equal(1, #result.incdirs)
    assert_equal("/mock/conf/mylib", result.incdirs[1])
    assert_equal(1, #result.headers)
    assert_equal("core.h", result.headers[1])
end)

-- ── multiple .h files in different subdirs ──────────────────────────────────

run_test("Returns unique dirs for .h files in different subdirs", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {
            conf = {
                ["mylib.h"] = true,
                ["mylib/core.h"] = true,
                ["mylib/util.h"] = true,
                ["other/util.h"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_not_nil(result)
    assert_equal(3, #result.incdirs)
    assert_equal(4, #result.headers)
end)

-- ── duplicate dirs are deduplicated ─────────────────────────────────────────

run_test("Deduplicates incdirs for .h files in same directory", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {
            conf = {
                ["mylib/core.h"] = true,
                ["mylib/util.h"] = true,
                ["mylib/extra.h"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_not_nil(result)
    assert_equal(1, #result.incdirs)
    assert_equal("/mock/conf/mylib", result.incdirs[1])
    assert_equal(3, #result.headers)
end)

-- ── double slashes in conf dir are normalized ───────────────────────────────

run_test("Normalizes double slashes in conf dir path", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock//conf/",
        },
        manifest = {
            conf = {
                ["mylib.h"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_not_nil(result)
    assert_equal(1, #result.incdirs)
    assert_equal("/mock/conf", result.incdirs[1])
end)

-- ── double slashes in nested path are normalized ────────────────────────────

run_test("Normalizes double slashes in nested .h path", function()
    mock_pkginfo.result = {
        dir = {
            conf = "/mock/conf",
        },
        manifest = {
            conf = {
                ["mylib//sub/core.h"] = true,
            },
        },
    }
    local result = incdirs("mylib")
    assert_not_nil(result)
    assert_equal(1, #result.incdirs)
    assert_equal("/mock/conf/mylib/sub", result.incdirs[1])
end)

-- ── passes pkgname to pkginfo ───────────────────────────────────────────────

run_test("Passes pkgname to pkginfo", function()
    mock_pkginfo.result = nil
    incdirs("testpkg")
    assert_equal("testpkg", mock_pkginfo.pkgname)
    assert_nil(mock_pkginfo.constraints)
end)

-- ── passes constraints to pkginfo ────────────────────────────────────────────

run_test("Passes constraints to pkginfo", function()
    mock_pkginfo.result = nil
    local constraints = {
        {
            op = "==",
            version = {
                1,
                0,
            },
        },
    }
    incdirs("testpkg", constraints)
    assert_equal("testpkg", mock_pkginfo.pkgname)
    assert_equal(constraints, mock_pkginfo.constraints)
end)
