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
--   When a variable value is a table, produces a cartesian product expansion:
--   standalone $(VAR) returns the table as-is; embedded "-L$(VAR)" maps each
--   element into the surrounding string.
-- For table input:   returns a new table (does not modify the input).
--   - Array elements resolving to nil are dropped (dense rebuild).
--   - Array elements where resolve_str returns a table are flattened.
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
local concat = table.concat

--- Expand table-valued variable substitutions via cartesian product.
--- Recursively substitutes each table-valued chunk with all its elements,
--- collecting non-empty concatenated results.
--- @param chunks table Array of string chunks with variable references as placeholders.
--- @param tblvlist table Array of variable reference items with .chunkno and .val.
--- @param idx? number Current position in tblvlist (default: 1).
--- @param results? table Accumulator for non-empty concatenated strings (default: {}).
--- @return table results Array of resolved non-empty strings (may be empty).
local function cartesian_concat(chunks, tblvlist, idx, results)
    idx = idx or 1
    results = results or {}
    if idx > #tblvlist then
        local str = concat(chunks)
        if #str > 0 then
            results[#results + 1] = str
        end
        return results
    end

    local item = tblvlist[idx]
    local chunk = chunks[item.chunkno]
    for _, val in ipairs(item.val) do
        chunks[item.chunkno] = val
        cartesian_concat(chunks, tblvlist, idx + 1, results)
    end
    chunks[item.chunkno] = chunk
    return results
end

-- Matches $(CONTENT)? where CONTENT contains no ) or whitespace.
local OUTER_PAT = '%$%(([^)%s]+)%)(%??)'
-- Modifier constants for the |env and :env suffixes.
local OR_ENV = 1 -- try rockspec.variables, then os.getenv
local FROM_ENV = 2 -- os.getenv only
local MODIFIER = {
    ['|env'] = OR_ENV,
    [':env'] = FROM_ENV,
}

--- Parse the next $(VAR...) expression starting from `pos`.
--- Returns item (a table with head, tail, name, val, or_env, from_env, optional)
--- when a variable reference is found and resolved.
--- Returns nil when no more patterns are found.
--- Returns (nil, errmsg) when a required variable cannot be resolved.
--- Unrecognized patterns (non-identifiers, unknown modifiers) are skipped
--- via tail-recursive call to the next position.
local function parse_next_variable(s, pos, variables)
    assert(type(s) == 'string')
    assert(type(pos) == 'number' and pos >= 1)
    assert(type(variables) == 'table')

    -- Find the next $(...) pattern starting from pos.
    local head, tail, content, opt = s:find(OUTER_PAT, pos)
    if not head then
        return nil
    end

    -- item will hold the parsed variable reference
    local item = {
        head = head,
        tail = tail,
        optional = opt == '?',
    }

    -- Parse the variable name (must be a LuaRocks-compatible identifier).
    head, tail = content:find('^[%a][%w_]*')
    if not head then
        return parse_next_variable(s, item.tail + 1, variables)
    end
    item.name = content:sub(head, tail)

    -- reminder after variable name, e.g. "|env"
    local rest = content:sub(tail + 1)
    -- check for supported modifiers
    local mod = MODIFIER[rest]
    local val
    if #rest == 0 then
        -- no modifier, default to rockspec.variables only
        val = variables[item.name]
    elseif mod == OR_ENV then
        -- try rockspec.variables first, then os.getenv
        item.or_env = true
        val = variables[item.name] or os.getenv(item.name)
    elseif mod == FROM_ENV then
        -- os.getenv only
        item.from_env = true
        val = os.getenv(item.name)
    else
        -- unrecognized modifier, skip this pattern and continue searching
        return parse_next_variable(s, item.tail + 1, variables)
    end

    -- Unwrap single-element tables to simplify downstream processing.
    if type(val) == 'table' then
        if #val > 1 then
            -- Multiple values: keep as table for cartesian product expansion in cartesian_concat.
            item.val = val
            return item
        end
        -- use the single element directly, which also allows empty tables to resolve to nil
        val = val[1]
    end

    -- Treat empty string as missing.
    if type(val) == 'string' and #val > 0 then
        item.val = val
    elseif item.optional then
        -- item.val may be nil for optional variables; caller will handle this case.
        item.val = ''
    else
        -- For required variables, error immediately.
        return nil, format('unresolved required variable %q',
                           '$(' .. item.name .. rest .. ')')
    end

    return item
end

--- Resolve all $(VAR...) expressions in a string (single-pass).
--- Phase 1: parse all variable references, splitting the string into chunks
---           of literal text and variable references.
--- Phase 2: apply string-valued substitutions (chunk index replacement).
--- Phase 3: expand table-valued variables via cartesian product on chunks.
--- Returns (string|table|nil, nil) on success, or (nil, errmsg) on failure.
--- Returns nil (not empty string) when the final result is empty.
--- @param s string Input string
--- @param variables table rockspec.variables
--- @return string|table|nil, string|nil
local function resolve_str(s, variables)
    local strvlist = {}
    local tblvlist = {}
    local vlist = {
        string = strvlist,
        table = tblvlist,
    }
    local chunks = {}
    local cur = 1

    -- Phase 1: parse all $(VAR) references and split into chunks
    local item, err = parse_next_variable(s, cur, variables)
    while item do
        if item.head > cur then
            chunks[#chunks + 1] = s:sub(cur, item.head - 1)
        end
        item.chunkno = #chunks + 1
        chunks[item.chunkno] = s:sub(item.head, item.tail)

        -- NOTE: type of item.val is string, table; if optional variable not
        -- found, it is set to '' which is a string. so, only string and table
        -- types are expected here.
        local list = assert(vlist[type(item.val)],
                            'unexpected variable value type: ' .. type(item.val))
        list[#list + 1] = item

        -- continue searching from the end of this pattern
        cur = item.tail + 1
        item, err = parse_next_variable(s, cur, variables)
    end
    if err then
        return nil, err
    end

    -- append the remainder of the string after the last variable reference
    if cur <= #s then
        chunks[#chunks + 1] = s:sub(cur)
    end

    -- Phase 2: apply string-valued substitutions
    for _, ref in ipairs(strvlist) do
        chunks[ref.chunkno] = ref.val
    end

    -- Phase 3: expand table-valued variables via cartesian product
    if #tblvlist == 0 then
        local result = concat(chunks)
        return #result > 0 and result or nil
    end

    local results = cartesian_concat(chunks, tblvlist)
    return #results > 0 and results or nil
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
        elseif type(resolved) == 'table' then
            -- Flatten cartesian product results from resolve_str;
            -- preserve nested table rebuilds as-is.
            if type(v) == 'string' then
                for _, elem in ipairs(resolved) do
                    result[#result + 1] = elem
                end
            else
                result[#result + 1] = resolved
            end
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
