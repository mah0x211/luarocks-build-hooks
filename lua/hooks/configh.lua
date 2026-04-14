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
local pairs = pairs
local type = type
local format = string.format
local generate = require('configh.generate')
local util = require('luarocks.util')

--- Normalize cfg.libs: split any space-separated string entries into
--- individual entries so configh receives discrete library names.
--- @param libs string[]
--- @return string[]
local function normalize_libs(libs)
    local result = {}
    for _, entry in ipairs(libs) do
        for lib in entry:gmatch('%S+') do
            result[#result + 1] = lib
        end
    end
    return result
end

--- Resolve $(VAR) placeholders in all string values inside a table,
--- recursively. Modifies the table in-place and returns it.
--- @param tbl table
--- @param variables table  rockspec.variables
--- @return table
local function resolve_vars(tbl, variables)
    for k, v in pairs(tbl) do
        if type(v) == 'string' then
            tbl[k] = v:gsub('%$%(([^)]+)%)', function(name)
                local val = variables[name]
                if type(val) == 'string' then
                    return val
                end
                return '$(' .. name .. ')'
            end)
        elseif type(v) == 'table' then
            resolve_vars(v, variables)
        end
    end
    return tbl
end

--- Deep-copy a table, avoiding reference cycles.
--- @param tbl table
--- @param visited table?
--- @return table
local function copy_table(tbl, visited)
    visited = visited or {}
    if visited[tbl] then
        return visited[tbl]
    end
    local t2 = {}
    visited[tbl] = t2
    for k, v in pairs(tbl) do
        if k ~= 'report' then
            if type(v) == 'table' then
                v = copy_table(v, visited)
            end
            t2[k] = v
        end
    end
    return t2
end

--- Run the $(configh) built-in hook.
--- Iterates rockspec.build.modules, and for each module table that contains
--- a `configh` sub-table, copies the sub-table, resolves $(VAR) placeholders
--- from rockspec.variables, normalizes cfg.libs, then calls
--- configh.generate() to produce the header file.
--- @param rockspec table
local function run_configh(rockspec)
    local modules = rockspec.build and rockspec.build.modules
    if type(modules) ~= 'table' then
        return
    end

    local variables = rockspec.variables or {}

    for modname, modtbl in pairs(modules) do
        if type(modtbl) == 'table' and modtbl.configh ~= nil then
            local configh_type = type(modtbl.configh)
            if configh_type ~= 'table' then
                error(format(
                          'build.modules[%q].configh must be a table, got %s',
                          modname, configh_type))
            end
            util.printout(format('hooks.configh: processing %s ...', modname))

            local cfg = copy_table(modtbl.configh)
            resolve_vars(cfg, variables)

            if type(cfg.libs) == 'table' then
                cfg.libs = normalize_libs(cfg.libs)
            end

            local label = format('build.modules[%q].configh', modname)
            local report, err = generate(cfg, label)
            if err then
                error(format('hooks.configh: %s: %s', label, err))
            end
            modtbl.configh.report = report
        end
    end
end

return run_configh
