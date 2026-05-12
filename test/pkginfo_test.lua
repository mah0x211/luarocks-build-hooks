require("luacov")

-- Mock framework
local function mock(name, value)
    package.loaded[name] = value
end

-- Mock luarocks.queries
mock("luarocks.queries", {
    new = function(pkgname, a, b, c)
        return {
            name = pkgname,
            a = a,
            b = b,
            c = c,
        }
    end,
})

-- Mock luarocks.search
local mock_pick_installed = {
    result = nil, -- { name, version, tree } or nil
}
mock_pick_installed.reset = function()
    mock_pick_installed.result = nil
end
mock("luarocks.search", {
    pick_installed_rock = function(query, root)
        mock_pick_installed.query = query
        mock_pick_installed.root = root
        if mock_pick_installed.result then
            return mock_pick_installed.result[1], mock_pick_installed.result[2],
                   mock_pick_installed.result[3]
        end
        return nil
    end,
})

-- Mock luarocks.manif
local mock_load_manifest = {
    result = nil, -- { manifest } or nil
    err = nil,
}
mock_load_manifest.reset = function()
    mock_load_manifest.result = nil
    mock_load_manifest.err = nil
end
mock("luarocks.manif", {
    load_rock_manifest = function(name, version, tree)
        mock_load_manifest.args = {
            name,
            version,
            tree,
        }
        return mock_load_manifest.result, mock_load_manifest.err
    end,
})

-- Mock luarocks.path
local mock_path = {
    rocks_dir_val = "/mock/rocks",
    root_val = "/mock/root",
    bin_dir_val = "/mock/bin",
    lua_dir_val = "/mock/lua",
    lib_dir_val = "/mock/lib",
    doc_dir_val = "/mock/doc",
    conf_dir_val = "/mock/conf",
    versions_dir_val = "/mock/versions",
    install_dir_val = "/mock/install",
    rock_manifest_file_val = "/mock/rock_manifest",
    rockspec_file_val = "/mock/rockspec",
    rock_namespace_file_val = "/mock/rock_namespace",
    read_namespace_val = nil,
}
mock_path.reset = function()
    mock_path.rocks_dir_val = "/mock/rocks"
    mock_path.root_val = "/mock/root"
    mock_path.bin_dir_val = "/mock/bin"
    mock_path.lua_dir_val = "/mock/lua"
    mock_path.lib_dir_val = "/mock/lib"
    mock_path.doc_dir_val = "/mock/doc"
    mock_path.conf_dir_val = "/mock/conf"
    mock_path.versions_dir_val = "/mock/versions"
    mock_path.install_dir_val = "/mock/install"
    mock_path.rock_manifest_file_val = "/mock/rock_manifest"
    mock_path.rockspec_file_val = "/mock/rockspec"
    mock_path.rock_namespace_file_val = "/mock/rock_namespace"
    mock_path.read_namespace_val = nil
end
mock("luarocks.path", {
    rocks_dir = function()
        return mock_path.rocks_dir_val
    end,
    root_from_rocks_dir = function(rocks_dir)
        mock_path.root_from_rocks_dir_arg = rocks_dir
        return mock_path.root_val
    end,
    bin_dir = function(name, version, tree)
        return mock_path.bin_dir_val
    end,
    lua_dir = function(name, version, tree)
        return mock_path.lua_dir_val
    end,
    lib_dir = function(name, version, tree)
        return mock_path.lib_dir_val
    end,
    doc_dir = function(name, version, tree)
        return mock_path.doc_dir_val
    end,
    conf_dir = function(name, version, tree)
        return mock_path.conf_dir_val
    end,
    versions_dir = function(name, tree)
        return mock_path.versions_dir_val
    end,
    install_dir = function(name, version, tree)
        return mock_path.install_dir_val
    end,
    rock_manifest_file = function(name, version, tree)
        return mock_path.rock_manifest_file_val
    end,
    rockspec_file = function(name, version, tree)
        return mock_path.rockspec_file_val
    end,
    rock_namespace_file = function(name, version, tree)
        return mock_path.rock_namespace_file_val
    end,
    read_namespace = function(name, version, tree)
        return mock_path.read_namespace_val
    end,
})

-- Load module under test (after mocks are in place)
local pkginfo = require("luarocks.build.hooks.lib.pkginfo")

-- Test helpers

local function run_test(name, func)
    io.write("Running " .. name .. "... ")
    mock_pick_installed.reset()
    mock_load_manifest.reset()
    mock_path.reset()
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

-- ── pick_installed_rock returns nil ──────────────────────────────────────────

run_test("Returns nil when rock not installed", function()
    mock_pick_installed.result = nil
    local result, err = pkginfo("nonexistent")
    assert_nil(result)
    assert_nil(err)
end)

-- ── passes correct args to pick_installed_rock ───────────────────────────────

run_test("Passes query and root to pick_installed_rock", function()
    mock_pick_installed.result = nil
    pkginfo("testpkg")
    assert_not_nil(mock_pick_installed.query)
    assert_equal("testpkg", mock_pick_installed.query.name)
    assert_equal("/mock/rocks", mock_path.root_from_rocks_dir_arg)
    assert_equal("/mock/root", mock_pick_installed.root)
end)

-- ── constraints are passed to query ──────────────────────────────────────────

run_test("Passes constraints to query when provided", function()
    mock_pick_installed.result = nil
    local constraints = {
        {
            op = "==",
            version = {
                1,
                0,
            },
        },
    }
    pkginfo("testpkg", constraints)
    assert_not_nil(mock_pick_installed.query)
    assert_equal(constraints, mock_pick_installed.query.constraints)
end)

-- ── constraints nil preserves default ────────────────────────────────────────

run_test("Keeps default constraints when nil is passed", function()
    mock_pick_installed.result = nil
    pkginfo("testpkg")
    assert_not_nil(mock_pick_installed.query)
    assert_nil(mock_pick_installed.query.constraints)
end)

-- ── load_manifest returns nil with error ─────────────────────────────────────

run_test("Returns nil and error when manifest fails to load", function()
    mock_pick_installed.result = {
        "mylib",
        "1.0",
        "/tree",
    }
    mock_load_manifest.result = nil
    mock_load_manifest.err = "manifest not found"
    local result, err = pkginfo("mylib")
    assert_nil(result)
    assert_equal("manifest not found", err)
end)

-- ── passes correct args to load_manifest ─────────────────────────────────────

run_test("Passes name, version, tree to load_manifest", function()
    mock_pick_installed.result = {
        "mypkg",
        "2.0",
        "/mytree",
    }
    mock_load_manifest.result = {
        lib = {},
    }
    pkginfo("mypkg")
    assert_equal("mypkg", mock_load_manifest.args[1])
    assert_equal("2.0", mock_load_manifest.args[2])
    assert_equal("/mytree", mock_load_manifest.args[3])
end)

-- ── returns full pkginfo table ───────────────────────────────────────────────

run_test("Returns full pkginfo table on success", function()
    mock_pick_installed.result = {
        "mylib",
        "1.0",
        "/tree",
    }
    mock_load_manifest.result = {
        lib = {
            "mylib.so",
        },
        conf = {
            "mylib.h",
        },
    }
    mock_path.read_namespace_val = "myns"
    local result, err = pkginfo("mylib")
    assert_nil(err)
    assert_not_nil(result)
    assert_equal("mylib", result.name)
    assert_equal("1.0", result.version)
    assert_equal("/tree", result.tree)
    assert_equal(mock_load_manifest.result, result.manifest)
    assert_equal("/mock/bin", result.dir.bin)
    assert_equal("/mock/lua", result.dir.lua)
    assert_equal("/mock/lib", result.dir.lib)
    assert_equal("/mock/doc", result.dir.doc)
    assert_equal("/mock/conf", result.dir.conf)
    assert_equal("/mock/versions", result.dir.versions)
    assert_equal("/mock/install", result.dir.install)
    assert_equal("/mock/rock_manifest", result.file.rock_manifest)
    assert_equal("/mock/rockspec", result.file.rockspec)
    assert_equal("/mock/rock_namespace", result.file.rock_namespace)
    assert_equal("myns", result.namespace)
end)

-- ── namespace is nil when read_namespace returns nil ─────────────────────────

run_test("Namespace is nil when read_namespace returns nil", function()
    mock_pick_installed.result = {
        "mylib",
        "1.0",
        "/tree",
    }
    mock_load_manifest.result = {}
    local result = pkginfo("mylib")
    assert_not_nil(result)
    assert_nil(result.namespace)
end)

-- ── assertion: pkgname must be a string ──────────────────────────────────────

run_test("Errors when pkgname is not a string", function()
    local ok, err = pcall(pkginfo, 123)
    assert_error("pkgname must be a string", ok and true or nil, err)
end)

-- ── assertion: constraints must be a table if provided ───────────────────────

run_test("Errors when constraints is not a table", function()
    local ok, err = pcall(pkginfo, "mylib", "not a table")
    assert_error("constraints must be a table", ok and true or nil, err)
end)
