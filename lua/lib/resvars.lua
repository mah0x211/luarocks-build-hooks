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
-- Supported syntax:
--   $(VAR)      - required; error if not found in rockspec.variables
--   $(VAR)?     - optional; empty string if not found in rockspec.variables
--   $(VAR|env)  - required; try rockspec.variables, then os.getenv
--   $(VAR:env)  - required; os.getenv only
--   $(VAR|env)? - optional version of $(VAR|env)
--   $(VAR:env)? - optional version of $(VAR:env)
--
-- Variable names must match [%a][%w_]* (LuaRocks-compatible identifiers).
-- Unrecognized patterns (e.g. raw pkgconfig refs with hyphens) are left as-is.
-- Substitution is single-pass: values are not re-expanded.
--
local type = type
local pairs = pairs
local format = string.format

-- Matches $(CONTENT)? where CONTENT contains no ) or whitespace.
local OUTER_PAT = '%$%(([^)%s]+)%)(%??)'

-- Modifier constants for the |env and :env suffixes.
local OR_ENV = 1 -- try rockspec.variables, then os.getenv
local FROM_ENV = 2 -- os.getenv only

local MODIFIER = {
    ['|env'] = OR_ENV,
    [':env'] = FROM_ENV,
}

--- Resolve a variable by name.
--- When with_env is true, variables (if non-nil) is tried first, then
--- os.getenv. Passing variables=nil with with_env=true is the FROM_ENV case.
--- @param name string Variable name
--- @param variables table|nil rockspec.variables
--- @param with_env boolean|nil
--- @return string|nil
local function resolve(name, variables, with_env)
    local v
    if with_env then
        v = (variables and variables[name]) or os.getenv(name)
    else
        v = variables and variables[name]
    end
    return (type(v) == 'string') and v or nil
end

--- Resolve all $(VAR...) expressions in a string (single-pass).
--- Returns (resolved_string, nil) on success or (nil, errmsg) on failure.
--- @param s string Input string
--- @param variables table rockspec.variables
--- @return string|nil, string|nil
local function resolve_str(s, variables)
    local errmsg
    local result = s:gsub(OUTER_PAT, function(str, opt)
        if errmsg then
            return
        end

        -- Extract identifier: must start with a letter
        local head, tail = str:find('^[%a][%w_]*')
        if not head then
            return -- no valid name: leave unchanged
        end
        local name = str:sub(head, tail)
        str = str:sub(tail + 1) -- remainder is the modifier part
        local mod = MODIFIER[str]

        -- Resolve based on modifier
        local v
        if #str == 0 then
            -- no modifier: vars only
            v = resolve(name, variables)
        elseif not mod then
            return -- unknown modifier: leave unchanged
        elseif mod == OR_ENV then
            v = resolve(name, variables, true)
        else -- FROM_ENV
            v = resolve(name, nil, true)
        end

        if not v then
            if opt == '?' then
                return ''
            end
            errmsg = format('unresolved required variable %q',
                            '$(' .. name .. str .. ')')
            return
        end
        return v
    end)
    if errmsg then
        return nil, errmsg
    end
    return result
end

--- Recursively resolve all string values in a table in-place (single-pass).
--- Returns (true, nil) on success or (nil, errmsg) on failure.
--- @param tbl table Table to process
--- @param variables table rockspec.variables
--- @return boolean|nil, string|nil
local function resolve_tbl(tbl, variables)
    for k, v in pairs(tbl) do
        if type(v) == 'string' then
            local resolved, err = resolve_str(v, variables)
            if err then
                return nil, err
            end
            tbl[k] = resolved
        elseif type(v) == 'table' then
            local ok, err = resolve_tbl(v, variables)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

--- Resolve all $(VAR...) expressions in a string or table.
--- For a string: returns (resolved_string, nil) on success.
--- For a table: resolves all string values in-place and returns (table, nil).
--- Returns (nil, errmsg) on failure.
--- @param target string|table Input string or table to process
--- @param variables table rockspec.variables
--- @return string|table|nil, string|nil
local function resvars(target, variables)
    variables = variables or {}
    if type(target) == 'string' then
        return resolve_str(target, variables)
    elseif type(target) == 'table' then
        local ok, err = resolve_tbl(target, variables)
        if not ok then
            return nil, err
        end
        return target
    else
        return nil, 'resvars: expected string or table, got ' .. type(target)
    end
end

return resvars
