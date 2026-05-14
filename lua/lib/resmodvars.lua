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
local resolve_vars = require('luarocks.build.hooks.lib.resvars')

--- Resolve $(VAR) expressions in a single value (string or table).
--- For strings, delegates to resolve_vars for substitution.
--- For tables, recursively resolves each array element and returns a new table
--- with nil results dropped (dense rebuild). Non-string, non-table values pass
--- through unchanged.
--- @param value string|table The value to resolve.
--- @param variables table rockspec.variables used for substitution.
--- @return string|table? resolved The resolved value, or nil on error/empty.
--- @return string? err Error message if resolution failed.
local function resolve_value(value, variables)
    if type(value) == 'string' then
        return resolve_vars(value, variables)
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

--- Resolve $(VAR) expressions in the whitelisted fields of a single module.
--- Modifies the module table in place: required fields that resolve to empty
--- produce an error; optional fields that resolve to empty are set to nil.
--- @param mname string Module name (used in error messages).
--- @param mod table The module definition table.
--- @param variables table rockspec.variables used for substitution.
--- @return boolean ok true on success, or false on error.
--- @return string? err Error message if resolution failed.
local function resolve_mod_fields(mname, mod, variables)
    for field, required in pairs(MODULE_FIELDS) do
        if mod[field] ~= nil then
            local v, err = resolve_value(mod[field], variables)
            if err then
                return false,
                       ('build.modules[%q].%s %s'):format(mname, field, err)
            elseif not v or (type(v) == 'table' and #v == 0) then
                if required then
                    return false,
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

--- Resolve $(VAR) expressions in all build.modules entries.
--- String modules are resolved as file paths (must not resolve to empty).
--- Table modules have only their whitelisted fields resolved via
--- resolve_mod_fields. Non-string, non-table module entries are skipped.
--- @param modules table The build.modules table to resolve.
--- @param variables table rockspec.variables used for substitution.
--- @return boolean ok true on success, or false on error.
--- @return string? err Error message if resolution failed.
local function resolve_modvars(modules, variables)
    if type(modules) ~= 'table' then
        return true
    end

    for mname, mod in pairs(modules) do
        if type(mod) == 'string' then
            local v, err = resolve_value(mod, variables)
            if not v then
                err = err or 'path resolved to empty string'
                return false, ('build.modules[%q] %s'):format(mname, err)
            end
            modules[mname] = v
        elseif type(mod) == 'table' then
            local ok, err = resolve_mod_fields(mname, mod, variables)
            if not ok then
                return false, err
            end
        end
    end

    return true
end

return resolve_modvars
