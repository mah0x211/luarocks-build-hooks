--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
local concat = table.concat
local unpack = unpack or table.unpack
local dump = require('dump')
local builtin = require('luarocks.build.builtin')
local fs = require('luarocks.fs')
local util = require('luarocks.util')
local chdir = require('luarocks.build.hooks.chdir')
local resvars = require('luarocks.build.hooks.lib.resvars')
local get_pkg_incdirs = require('luarocks.build.hooks.lib.incdirs')

local function resolve_value(value, variables)
    if type(value) == 'string' then
        return resvars(value, variables)
    elseif type(value) ~= 'table' then
        return value
    end

    local t = {}
    for _, v in ipairs(value) do
        local resolved, err = resolve_value(v, variables)
        if err then
            return nil, err
        elseif resolved ~= nil then
            t[#t + 1] = resolved
        end
    end
    return t
end

-- Whitelisted per-module fields: true = error when resolved to empty,
-- false = delete field when resolved to empty.
local MODULE_FIELDS = {
    sources = true,
    incdirs = false,
    libdirs = false,
    libraries = false,
    defines = false,
}

local function resolve_mod_fields(mname, mod, variables)
    for field, required in pairs(MODULE_FIELDS) do
        if mod[field] ~= nil then
            local v, err = resolve_value(mod[field], variables)
            if err then
                return nil,
                       ('build.modules[%q].%s %s'):format(mname, field, err)
            elseif not v or (type(v) == 'table' and #v == 0) then
                if required then
                    return nil,
                           ('build.modules[%q].%s resolved to empty string'):format(
                               mname, field)
                end
                v = nil
            end
            mod[field] = v
        end
    end
    return true
end

local function resolve_modvars(rockspec)
    local modules = rockspec.build and rockspec.build.modules
    if type(modules) ~= 'table' then
        return true
    end

    local variables = rockspec.variables
    for mname, mod in pairs(modules) do
        if type(mod) == 'string' then
            local v, err = resolve_value(mod, variables)
            if not v then
                err = err or 'path resolved to empty string'
                return nil, ('build.modules[%q] %s'):format(mname, err)
            end
            modules[mname] = v
        elseif type(mod) == 'table' then
            local ok, err = resolve_mod_fields(mname, mod, variables)
            if not ok then
                return nil, err
            end
        end
    end

    return true
end

--- Create a shallow copy of a table, recursively copying any nested tables.
local function copy_table(tbl, visited)
    if tbl == nil then
        return nil
    end

    visited = visited or {}
    if visited[tbl] then
        return visited[tbl]
    end

    local t2 = {}
    visited[tbl] = t2
    for k, v in pairs(tbl) do
        if type(v) == 'table' then
            v = copy_table(v, visited)
        end
        t2[k] = v
    end
    return t2
end

--- Create an environment table for executing hook scripts.
local function getenv()
    local env = {
        _G = nil, -- placeholder
        _VERSION = _VERSION,

        -- Lua 5.1
        assert = assert,
        collectgarbage = collectgarbage,
        dofile = dofile,
        error = error,
        getfenv = getfenv,
        getmetatable = getmetatable,
        ipairs = ipairs,
        load = load,
        loadfile = loadfile,
        loadstring = loadstring,
        module = module,
        next = next,
        pairs = pairs,
        pcall = pcall,
        print = print,
        rawequal = rawequal,
        rawget = rawget,
        rawset = rawset,
        require = require,
        select = select,
        setfenv = setfenv,
        setmetatable = setmetatable,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        xpcall = xpcall,

        coroutine = copy_table(coroutine),
        debug = copy_table(debug),
        io = copy_table(io),
        math = copy_table(math),
        os = copy_table(os),
        package = copy_table(package),
        string = copy_table(string),
        table = copy_table(table),

        unpack = unpack or table.unpack, -- table.unpack in Lua 5.2+
        bit32 = copy_table(_G.bit32), -- Lua 5.2+
        warn = _G.warn, -- Lua 5.4+
        utf8 = copy_table(_G.utf8), -- Lua 5.3+
    }
    env._G = env
    return env
end

--- Load a hook file as a chunk.
--- @param pathname string The hook file path.
--- @return function? chunk fn The loaded chunk, or nil on failure.
--- @return any err An error message on failure.
local function load_hook(pathname)
    -- Load as file
    if not fs.exists(pathname) then
        return nil, ('%q hook script not found'):format(pathname)
    end

    local env = getenv()
    local chunk, err
    if _G.setfenv then
        chunk, err = loadfile(pathname)
        if chunk then
            _G.setfenv(chunk, env)
        end
    else
        chunk, err = loadfile(pathname, 'bt', env)
    end

    if err then
        return nil, ('Failed to load hook script %q: %s'):format(pathname, err)
    end
    return chunk
end

--- Load a builtin hook module from its name.
--- @param pathname string The hook string to parse.
--- @return function? fn The loaded module, or nil on failure.
--- @return any err An error message on failure.
local function load_builtin_hook(pathname)
    local whole, name = pathname:match('^(%s*%$%(([^)%s]*))')
    if not whole then
        -- Not a builtin hook attempt
        return
    elseif not pathname:find('^%)%s*$', #whole + 1) then
        return nil, 'Invalid builtin hook syntax'
    elseif #name == 0 then
        return nil, 'Invalid builtin hook syntax: missing name'
    end

    -- Load hook as submodule via require
    local ok, mod = pcall(require, 'luarocks.build.hooks.' .. name)
    if not ok then
        return nil, ('Failed to load builtin-hook %s: %s'):format(name, mod)
    elseif type(mod) ~= 'function' then
        return nil, ('Invalid builtin-hook %s: not a function'):format(name)
    end
    return mod
end

--- @class builtin.hook
--- @field spec_name string The name of the hook in the rockspec.
--- @field value string The original hook string.
--- @field pathname string The hook file path.
--- @field args string[] The arguments to pass to the hook
--- @field func function The loaded hook function.

--- Parse a hook string into its components.
--- @param str string The hook string to parse.
--- @return builtin.hook? hook The parsed hook
--- @return any err An error message on failure.
local function parse_hook(str)
    local hook = {
        args = {},
    }
    for match in str:gmatch('([^%s]+)') do
        hook.args[#hook.args + 1] = match
    end
    -- Reconstruct original hook string
    hook.value = concat(hook.args, ' ')
    -- First argument is the hook pathname
    hook.pathname = table.remove(hook.args, 1)

    -- Try to load as builtin hook
    local err
    hook.func, err = load_builtin_hook(hook.pathname)
    if not err and not hook.func then
        -- Load as script file
        hook.func, err = load_hook(hook.pathname)
    end

    if err then
        -- Failed to load as builtin hook
        return nil, err
    end
    return hook
end

local function parse_hooks(rockspec, name)
    local spec_key = 'build.' .. name
    local build = rockspec.build
    local hooks = build[name]
    if not hooks then
        return {} -- no hooks
    end

    local is_array = false
    local hook_type = type(hooks)
    if hook_type == 'string' then
        hooks = {
            build[name],
        }
    elseif hook_type ~= 'table' then
        return nil, ('Invalid hook type: %s'):format(hook_type)
    elseif #hooks == 0 then
        return {} -- no hooks
    else
        is_array = true
        -- confirm it's an array of strings
        local nhooks = #hooks
        local count = 0
        for _, v in pairs(hooks) do
            count = count + 1
            if count > nhooks or type(v) ~= 'string' then
                return nil, ('%s must be an array of strings'):format(spec_key)
            end
        end
    end

    -- parse hooks
    for i, str in ipairs(hooks) do
        local idx = is_array and ('#%d'):format(i) or ''
        local t = type(str)
        if t ~= 'string' then
            return nil, ('%s%s must be a string: %s'):format(spec_key, idx, t)
        end

        -- parse hook string
        local hook, err = parse_hook(str)
        if err then
            return nil, ('%s%s: %s'):format(spec_key, idx, err)
        end
        hook.spec_name = ('%s%s'):format(spec_key, idx)
        hooks[i] = hook
    end

    return hooks
end

local function run_hook(hook, rockspec)
    return xpcall(function()
        hook.func(rockspec, unpack(hook.args))
    end, debug.traceback)
end

local function run_hooks(rockspec, no_install)
    local before_hooks, after_hooks, err

    -- Parse before_build hooks
    before_hooks, err = parse_hooks(rockspec, 'before_build')
    if not before_hooks then
        return nil, err
    end
    after_hooks, err = parse_hooks(rockspec, 'after_build')
    if not after_hooks then
        return nil, err
    end

    -- 1. Run before_build if present
    local ok
    for _, hook in ipairs(before_hooks) do
        util.printout('Running hook: ' .. hook.value)
        ok, err = run_hook(hook, rockspec)
        if not ok then
            return false, ('Failed to run %q: %s'):format(hook.spec_name, err)
        end
    end

    -- 2. Resolve variables in whitelisted module fields
    ok, err = resolve_modvars(rockspec)
    if not ok then
        return nil, err
    end

    -- 3. Delegate to standard builtin backend
    ok, err = builtin.run(rockspec, no_install)
    if not ok then
        return nil, err
    end

    -- 4. Run after_build if present
    for _, hook in ipairs(after_hooks) do
        util.printout('Running hook: ' .. hook.value)
        ok, err = run_hook(hook, rockspec)
        if not ok then
            return false, ('Failed to run %q: %s'):format(hook.spec_name, err)
        end
    end

    return true
end

--- Append include directories from dependencies to a module's incdirs field.
--- @param mod table The module to modify.
--- @param extra_incdirs string[]? The include directories to append.
--- @return boolean ok true if the module was modified.
local function append_extra_incdirs(mod, extra_incdirs)
    if extra_incdirs == nil then
        -- no extra incdirs to add, skip modification
        return false
    end
    assert(type(extra_incdirs) == 'table')

    local incdirs = mod.incdirs

    -- no existing incdirs, set to incdirs from dependencies
    if incdirs == nil then
        mod.incdirs = extra_incdirs
        return true
    end

    -- convert incdirs field to array if it's a string
    if type(incdirs) == 'string' then
        -- convert to array
        incdirs = {
            incdirs,
        }
    elseif type(incdirs) ~= 'table' then
        -- invalid incdirs type, skip modification
        return false
    end

    -- list of existing incdirs for deduplication
    local nodup = {}
    for _, dir in ipairs(incdirs) do
        nodup[dir] = true
    end

    -- append extra incdirs, skipping duplicates
    for _, dir in ipairs(extra_incdirs) do
        if not nodup[dir] then
            nodup[dir] = true
            incdirs[#incdirs + 1] = dir
        end
    end
    -- update mod.incdirs with the combined list
    mod.incdirs = incdirs
    return true
end

--- Get include directories from dependencies of the rockspec.
--- @param rockspec table The rockspec to analyze.
--- @return string[]? A list of include directories from dependencies
--- @return table? A table mapping dependency package names to their include directories, for debugging purposes.
local function get_deps_incdirs(rockspec)
    local packages = {}
    local incdirs = {}
    for _, dep in ipairs(rockspec.dependencies or {}) do
        local pkg_incdirs, err = get_pkg_incdirs(dep.name, dep.constraints)
        if pkg_incdirs then
            -- Add include directories from this dependency to the list
            for _, dir in ipairs(pkg_incdirs.incdirs) do
                incdirs[#incdirs + 1] = dir
            end
            -- Also add to packages list for debugging purposes
            packages[dep.name] = pkg_incdirs
        elseif err then
            util.printout(
                ('Warning: Failed to get include directories for dependency %q: %s'):format(
                    dep.name, err))
        end
    end

    if #incdirs > 0 then
        return incdirs, packages
    end
end

local function check_cmodule(mod)
    if type(mod) == 'string' then
        if mod:find('%.c$') then
            -- found a C module, convert to table form for easier processing
            return {
                sources = {
                    mod,
                },
            }
        end
    elseif type(mod) ~= 'table' then
        -- invalid module type, skip
        return
    elseif type(mod.sources) == 'string' then
        if mod.sources:find('%.c$') then
            -- convert sources field to array if it's a string
            mod.sources = {
                mod.sources,
            }
            return mod
        end
    elseif type(mod.sources) == 'table' then
        for _, src in ipairs(mod.sources) do
            if type(src) == 'string' and src:find('%.c$') then
                -- found a C source file, keep this module
                return mod
            end
        end
    end
    -- not a C module, skip
end

--- Add include directories from dependencies to C modules in the rockspec.
--- @param rockspec table The rockspec to modify.
local function add_deps_incdirs(rockspec)
    -- list all c modules
    local modules = rockspec.build.modules
    local get_deps_incdirs_once = false
    local incdirs

    for name, mod in pairs(modules or {}) do
        mod = check_cmodule(mod)
        if mod then
            if not get_deps_incdirs_once then
                -- Get include directories from dependencies only once, before
                -- processing the first C module, since the same incdirs can be
                -- applied to all C modules and there's no need to repeat this
                -- potentially expensive operation for each C module.
                get_deps_incdirs_once = true
                local packages
                incdirs, packages = get_deps_incdirs(rockspec)
                if incdirs then
                    util.printout(
                        ('Add include directories from dependencies to C modules: %s'):format(
                            dump(packages)))
                end
            end

            if append_extra_incdirs(mod, incdirs) then
                -- overwrite module in rockspec with updated incdirs field
                modules[name] = mod
            end
        end
        -- not a C module, skip
    end
end

local function run(rockspec, no_install)
    local target_dir = fs and fs.current_dir and fs.current_dir() or '.'
    util.printout(('Changing working directory to %s'):format(target_dir))

    local cwd = assert(chdir(target_dir))
    local ok, res, err = pcall(function()
        -- Add include directories from dependencies to C modules before running
        -- hooks, so that hooks can rely on the presence of these incdirs in the
        -- rockspec for any C modules when they run.
        add_deps_incdirs(rockspec)

        -- Delegate to run_hooks, which will run before_build hooks, then the
        -- standard build process, then after_build hooks.
        return run_hooks(rockspec, no_install)
    end)

    util.printout(('Restoring working directory to %s'):format(cwd))
    assert(chdir(cwd))

    if not ok then
        return nil, res
    end
    return res, err
end

return {
    run = run,
}
