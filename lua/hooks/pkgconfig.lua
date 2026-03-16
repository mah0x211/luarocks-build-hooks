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
local util = require("luarocks.util")

--- Process a libraries array, expanding any standalone $(VAR_NAME) entries into
--- individual library names. Raises an error if the reference is embedded within
--- a larger string. Returns the original table if no expansion was needed.
--- @param libs string[] The libraries array to process
--- @param lib_names string[] Library names to expand into
--- @param var_name string The normalized *_LIB variable name (e.g. "OPENSSL_LIB")
--- @return string[] The processed libraries array (new table if expanded)
local function expand_libraries(libs, lib_names, var_name)
    local var_pat = '%$%(' .. var_name .. '%)'
    local var_ref = ('$(%s)'):format(var_name)
    local new_libs = {}
    local changed = false
    for _, entry in ipairs(libs) do
        if entry:find(var_pat) then
            local remainder = entry:gsub(var_pat, "")
            if remainder:match('%S') then
                error(("%s resolves to multiple libraries and cannot " ..
                          "be embedded in a library entry: %q"):format(var_ref,
                                                                       entry))
            end
            changed = true
        else
            new_libs[#new_libs + 1] = entry
        end
    end

    -- No entries contained the variable reference, so no expansion needed.
    if not changed then
        return libs
    end

    -- Expand the variable reference into individual library names.
    for _, lib in ipairs(lib_names) do
        new_libs[#new_libs + 1] = lib
    end
    return new_libs
end

--- Expand multi-lib $(VAR_LIB) entries in the libraries field of target modules.
--- Only expands when lib_names contains more than one library name.
--- Single-lib entries are left as-is for LuaRocks to substitute natively.
--- Raises an error if the variable reference is embedded within a larger string,
--- since a multi-lib variable cannot be meaningfully embedded.
--- @param targets table  Map of module name to module table (from get_target_modules)
--- @param var_name string The normalized *_LIB variable name (e.g. "OPENSSL_LIB")
--- @param lib_names string[] Library names extracted from Libs (empty = no-op)
local function expand_lib_vars(targets, var_name, lib_names)
    if #lib_names < 2 then
        return
    end

    for _, mod in pairs(targets) do
        local libs = mod.libraries
        if type(libs) == 'table' then
            local result = expand_libraries(libs, lib_names, var_name)
            if result ~= libs then
                mod.libraries = result
            end
        end
    end
end

local function update_variables(variables, new_vars, old_vars)
    -- Log added and updated variables
    for k, v in pairs(new_vars) do
        local old_val = old_vars[k]
        local msg = ("    kept %s = %s"):format(k, v)
        if not old_val then
            msg = ("    added %s = %s"):format(k, v)
        elseif old_val ~= v then
            msg = ("    updated %s = %s (replaced %s)"):format(k, v, old_val)
        end
        util.printout(msg)
        old_vars[k] = nil
        variables[k] = v
    end

    -- Log old variables that were removed
    for k, v in pairs(old_vars) do
        util.printout(("    removed %s = %s"):format(k, v))
    end
end

--- Get all pkg-config variables and metadata for a given package
--- @param pkg string name
--- @return table? vars all variables and metadata fields
--- @return string? err error message if failed to get variables
local function get_pkg_variables(pkg)
    local f, err = io.popen(([[
pkg="%s"
# Locate .pc file for the package
pcdir=$(pkg-config --variable=pcfiledir "$pkg" 2>/dev/null)
if [ -n "$pcdir" ]; then
    # Construct full path to .pc file
    pcfile="$pcdir/$pkg.pc"

    # Extract variable definitions
    for v in $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pcfile" | sed 's/=.*$//' || true); do
        printf '%%s=%%s\n' "$v" "$(pkg-config --variable="$v" "$pkg" 2>/dev/null)"
    done

    # Extract metadata fields
    grep -E '^(Name|Description|Version):\s*' "$pcfile" | sed 's/:\s*/=/' || true

    # Get computed values
    printf 'Libs=%%s\n' "$(pkg-config --libs "$pkg" 2>/dev/null || true)"
    printf 'Cflags=%%s\n' "$(pkg-config --cflags "$pkg" 2>/dev/null || true)"
    printf 'Modversion=%%s\n' "$(pkg-config --modversion "$pkg" 2>/dev/null || true)"
fi
]]):format(pkg))

    local res = {}
    if not f then
        return nil, err
    end

    -- Parse all key=value pairs
    for line in f:lines() do
        local key, val = line:match("^([^=]+)=(.*)$")
        if key and val ~= "" then
            -- Trim leading and trailing whitespace from value
            res[key] = val:match("^%s*(.-)%s*$")
        end
    end
    f:close()

    -- Display package information
    if res.Name or res.Description then
        local info = res.Name or pkg
        if res.Description then
            info = info .. " - " .. res.Description
        end
        util.printout(("    %s"):format(info))
    end
    if res.Modversion then
        util.printout(("    Version: %s"):format(res.Modversion))
    end

    return res
end

--- Find package with case-insensitive exact match and get suggestions
--- @param pkg string name to search for
--- @return string? package name if found (case-insensitive), nil otherwise
--- @return string[]? suggested package names (partial matches)
local function find_package(pkg)
    -- Use grep to filter packages, then awk to extract package names only
    local f = io.popen(concat({
        'pkg-config --list-all 2>/dev/null |',
        ('grep -i %s |'):format(pkg),
        "awk '{print $1}'",
    }, ' '))
    if not f then
        return
    end

    local suggestions = {}
    for line in f:lines() do
        local name = line:match("^%s*(%S+)%s*$")
        if name then
            -- Exact case-sensitive match - return immediately
            if name == pkg then
                return name
            end

            -- Collect for suggestions (as array)
            suggestions[#suggestions + 1] = name

            -- Build namelist for case-insensitive lookup (handle multiple packages with same lowercase name)
            local lname = name:lower()
            local namelist = suggestions[lname]
            if not namelist then
                namelist = {}
                suggestions[lname] = namelist
            end
            namelist[#namelist + 1] = name

        end
    end
    f:close()

    local namelist = suggestions[pkg:lower()]
    return namelist and namelist[1] or nil, suggestions
end

local VAR_MAP = {
    includedir = "INCDIR",
    libdir = "LIBDIR",
    prefix = "DIR",
    bindir = "BINDIR",
}

--- Resolve a single external dependency using pkg-config
--- @param rockspec table The rockspec table
--- @param pkginfo pkginfo The pkginfo table from make_pkginfo
local function resolve_one(rockspec, pkginfo)
    local pkgname, suggestions = find_package(pkginfo.name)
    if not pkgname then
        util.printout(("    %s is not registered in pkg-config."):format(
                          pkginfo.name))
        if suggestions and #suggestions > 0 then
            util.printout(("    Did you mean: %s?"):format(concat(suggestions,
                                                                  ', ')))
        end
        return
    elseif pkgname ~= pkginfo.name then
        util.printout(("    resolved to %s"):format(pkgname))
    end

    local pkg_data, err = get_pkg_variables(pkgname)
    if not pkg_data then
        util.printout(("    failed to get pkg-config data: %s"):format(err or
                                                                           "unknown error"))
        return
    end

    local new_vars = {}
    for varname, val in pairs(pkg_data) do
        local suffix = VAR_MAP[varname] or varname:upper()
        new_vars[pkginfo.prefix .. suffix] = val
    end

    -- Synthesize *_LIB: all library names from Libs, space-separated (no -l prefix).
    -- This enables libraries = { "$(PREFIX_LIB)" } in rockspecs.
    local lib_names = {}
    if pkg_data.Libs then
        for lib in pkg_data.Libs:gmatch('%-l(%S+)') do
            lib_names[#lib_names + 1] = lib
        end
        if #lib_names > 0 then
            new_vars[pkginfo.prefix .. "LIB"] = concat(lib_names, ' ')
        end
    end

    update_variables(rockspec.variables, new_vars, pkginfo.vars)
    expand_lib_vars(pkginfo.targets, pkginfo.prefix .. "LIB", lib_names)
end

--- Replace all plain (non-pattern) occurrences of `old` with `new_str` in `s`.
--- Returns the resulting string and a boolean indicating whether any replacement
--- was made.
--- @param s string
--- @param old_str string
--- @param new_str string
--- @return string result, boolean changed
local function str_replace_all(s, old_str, new_str)
    local parts = {}
    local pos = 1
    local i, j = s:find(old_str, pos, true)
    while i do
        parts[#parts + 1] = s:sub(pos, i - 1)
        parts[#parts + 1] = new_str
        pos = j + 1
        i, j = s:find(old_str, pos, true)
    end
    if pos <= #s then
        parts[#parts + 1] = s:sub(pos)
    end
    return table.concat(parts), #parts > 1
end

--- Check a single module field for raw dep variable references, normalizing
--- them in-place if found. If the field value is a plain string it is wrapped
--- in a single-element array so the rest of the pipeline can treat all fields
--- as arrays uniformly.
--- Returns the (possibly converted) array when at least one dep var reference
--- was found, or nil when no reference is present.
--- @param pkginfo pkginfo The pkginfo table from make_pkginfo
--- @param modname string The module name (used in error messages)
--- @param field string The field name (used in error messages, e.g. "libraries")
--- @param vals string|string[]|nil The raw field value
--- @return string[]? vals The normalized array, or nil if no dep var ref found
local function check_target_field(pkginfo, modname, field, vals)
    if vals == nil then
        return
    elseif type(vals) == "string" then
        vals = {
            vals,
        }
    elseif type(vals) ~= "table" then
        error(("%s.%s: expected string or table, got %s"):format(modname, field,
                                                                 type(vals)))
    end

    local result
    for i, entry in ipairs(vals) do
        for _, suffix in ipairs({
            "LIB",
            "INCDIR",
            "LIBDIR",
        }) do
            local raw_ref = "$(" .. pkginfo.raw_prefix .. suffix .. ")"
            local norm_ref = "$(" .. pkginfo.prefix .. suffix .. ")"
            if raw_ref ~= norm_ref then
                local new_entry, changed =
                    str_replace_all(entry, raw_ref, norm_ref)
                if changed then
                    vals[i] = new_entry
                    entry = new_entry
                    result = vals
                end
            elseif entry:find(raw_ref, 1, true) then
                result = vals
            end
        end
    end
    return result
end

--- Find all build modules that reference variables for the named external
--- dependency using the raw (non-normalized) prefix form only, and normalize
--- those references in-place to the LuaRocks-compatible form.
--- Any field among libraries/incdirs/libdirs that is a plain string is converted
--- to a single-element array so that the rest of the pipeline can always treat
--- those fields as tables.
--- @param rockspec table The rockspec table
--- @param pkginfo pkginfo The pkginfo table from make_pkginfo
--- @return pkginfo pkginfo The updated pkginfo with targets referencing this dependency
local function get_target_modules(rockspec, pkginfo)
    local targets = pkginfo.targets
    local modules = rockspec.build and rockspec.build.modules
    if type(modules) ~= "table" then
        return pkginfo
    end

    for modname, mod in pairs(modules) do
        if type(mod) == "table" then
            for _, field in ipairs({
                "libraries",
                "incdirs",
                "libdirs",
            }) do
                local vals = check_target_field(pkginfo, modname, field,
                                                mod[field])
                if vals then
                    mod[field] = vals
                    targets[modname] = mod
                end
            end
        end
    end

    return pkginfo
end

--- Extract variables with keys starting with prefix from variables table
--- Removes the extracted variables from the original table and returns them in
--- a new table.
--- @param variables table The original variables table to extract from and modify
--- @param prefix string The prefix to match keys against (e.g. "LIBFOO2-8_")
--- @return table extracted The extracted variables with keys starting with prefix and their values
local function extract_variables(variables, prefix)
    local extracted = {}
    for k, v in pairs(variables) do
        if k:find(prefix, 1, true) == 1 then
            extracted[k] = v
            variables[k] = nil
        end
    end
    return extracted
end

--- Normalize a string to a valid LuaRocks variable name.
--- LuaRocks variable substitution $(NAME) only recognizes names starting with
--- a letter and containing only letters, digits, and underscores. This function
--- replaces any other character with an underscore.
--- @param s string
--- @return string
local function normalize_varname(s)
    local res = s:gsub("[^%a%d_]", "_")
    return res
end

--- @class pkginfo
--- @field name string original dep name (e.g. "LIBFOO2-8")
--- @field raw_prefix string raw uppercase prefix (e.g. "LIBFOO2-8_")
--- @field prefix string normalized prefix (e.g. "LIBFOO2_8_")
--- @field vars table variables extracted from rockspec.variables whose key
---                   starts with raw_prefix.
--- @field targets table modules referencing this dep's raw-form vars

--- Build a structured info object for a single external dependency.
--- @param rockspec table The rockspec table
--- @param name string The dependency name from external_dependencies
--- @return pkginfo pkginfo
local function make_pkginfo(rockspec, name)
    local raw_prefix = name:upper() .. "_"
    local prefix = normalize_varname(raw_prefix)

    local raw_vars = extract_variables(rockspec.variables, raw_prefix)
    local vars = {}
    for k, v in pairs(raw_vars) do
        local nk = normalize_varname(k)
        if k ~= nk then
            util.printout(("    normalizing %s -> %s"):format(k, nk))
        end
        vars[nk] = v
    end

    return get_target_modules(rockspec, {
        name = name,
        raw_prefix = raw_prefix,
        prefix = prefix,
        vars = vars,
        targets = {},
    })
end

--- Resolve dependencies using pkg-config
--- @param rockspec table The rockspec table
local function resolve_pkgconfig(rockspec)
    local ext_deps = rockspec.external_dependencies
    if not ext_deps then
        return
    end

    util.printout("hooks.pkgconfig: resolving external dependencies...")
    for name, _ in pairs(ext_deps) do
        util.printout(("  checking %s ..."):format(name))
        local pkginfo = make_pkginfo(rockspec, name)
        resolve_one(rockspec, pkginfo)
    end
end

return resolve_pkgconfig
