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
--   $(VAR)      - required; error if not found or empty in rockspec.variables
--   $(VAR)?     - optional; nil if not found or empty in rockspec.variables
--   $(VAR|env)  - required; try rockspec.variables, then os.getenv
--   $(VAR:env)  - required; os.getenv only
--   $(VAR|env)? - optional version of $(VAR|env)
--   $(VAR:env)? - optional version of $(VAR:env)
--
-- An empty string ("") in variables or os.getenv is treated as missing.
--
-- For string input:  returns nil if the final result is empty.
-- For table input:   returns a new table (does not modify the input).
--   - Array elements resolving to nil are dropped (dense rebuild).
--   - Map keys resolving to nil are omitted.
--   - Empty child tables ({}) are preserved.
--
-- Variable names must match [%a][%w_]* (LuaRocks-compatible identifiers).
-- Unrecognized patterns (e.g. raw pkgconfig refs with hyphens) are left as-is.
-- Substitution is single-pass: values are not re-expanded.
--
local type = type
local ipairs = ipairs
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

--- Resolve a variable by name.  Empty strings are treated as missing.
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
    return (type(v) == 'string') and #v > 0 and v or nil
end

--- Resolve all $(VAR...) expressions in a string (single-pass).
--- Returns (resolved_string, nil) on success, or (nil, errmsg) on failure.
--- Returns nil (not empty string) when the final result is empty.
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
    return #result > 0 and result or nil
end

--- Build a new table with all string values resolved (single-pass).
--- Array elements that resolve to nil are dropped (dense rebuild).
--- Map keys that resolve to nil are omitted.
--- Empty child tables ({}) are preserved.
--- Returns (new_table, nil) on success or (nil, errmsg) on failure.
--- @param tbl table Input table
--- @param variables table rockspec.variables
--- @return table|nil, string|nil
local function rebuild_tbl(tbl, variables)
    local result = {}

    -- Process the sequence portion (integer keys 1..n) first,
    -- recording visited keys to skip them in the map pass.
    local dedup = {}
    for i, v in ipairs(tbl) do
        dedup[i] = true
        local resolved, err
        if type(v) == 'string' then
            resolved, err = resolve_str(v, variables)
        elseif type(v) == 'table' then
            resolved, err = rebuild_tbl(v, variables)
        else
            resolved = v
        end

        if err then
            return nil, err
        elseif resolved ~= nil then
            result[#result + 1] = resolved
        end
    end

    -- Process the map portion, skipping keys already handled above.
    for k, v in pairs(tbl) do
        if not dedup[k] then
            local resolved, err
            if type(v) == 'string' then
                resolved, err = resolve_str(v, variables)
            elseif type(v) == 'table' then
                resolved, err = rebuild_tbl(v, variables)
            else
                resolved = v
            end

            if err then
                return nil, err
            elseif resolved ~= nil then
                result[k] = resolved
            end
        end
    end

    return result
end

--- Resolve all $(VAR...) expressions in a string or table.
--- For a string: returns (resolved_string, nil) on success, nil if result is empty.
--- For a table:  returns (new_table, nil) — never modifies the input table.
--- Returns (nil, errmsg) on failure.
--- @param target string|table Input string or table to process
--- @param variables table rockspec.variables
--- @return string|table|nil, string|nil
local function resolve_vars(target, variables)
    variables = variables or {}
    if type(target) == 'string' then
        return resolve_str(target, variables)
    elseif type(target) == 'table' then
        return rebuild_tbl(target, variables)
    else
        return nil,
               'resolve_vars: expected string or table, got ' .. type(target)
    end
end

return resolve_vars
