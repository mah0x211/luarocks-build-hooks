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
local util = require('luarocks.util')
local fs = require('luarocks.fs')

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
            local remainder = entry:gsub(var_pat, '')
            if remainder:match('%S') then
                error(('%s resolves to multiple libraries and cannot ' ..
                          'be embedded in a library entry: %q'):format(var_ref,
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
--- Only expands when pkginfo.pkgdep.library contains more than one library name.
--- Single-lib entries are left as-is for LuaRocks to substitute natively.
--- Raises an error if the variable reference is embedded within a larger string,
--- since a multi-lib variable cannot be meaningfully embedded.
--- @param targets table  Map of module name to module table (from get_target_modules)
--- @param pkginfo pkginfo The pkginfo table from make_pkginfo
local function expand_lib_vars(targets, pkginfo)
    local library = pkginfo.pkgdep and pkginfo.pkgdep.library
    if not library then
        return
    end

    -- library may be a string (single name, space-separated list from pkg-config,
    -- or mutated by resolve_one) or an array from the rockspec.
    local lib_names = {}
    if type(library) == 'table' then
        for _, lib in ipairs(library) do
            lib_names[#lib_names + 1] = lib
        end
    else
        for lib in library:gmatch('%S+') do
            lib_names[#lib_names + 1] = lib
        end
    end
    if #lib_names < 2 then
        return
    end

    local var_name = pkginfo.prefix .. 'LIB'
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
        local msg = ('    kept %s = %s'):format(k, v)
        if not old_val then
            msg = ('    added %s = %s'):format(k, v)
        elseif old_val ~= v then
            msg = ('    updated %s = %s (replaced %s)'):format(k, v, old_val)
        end
        util.printout(msg)
        old_vars[k] = nil
        variables[k] = v
    end

    -- Log old variables that were removed
    for k, v in pairs(old_vars) do
        util.printout(('    removed %s = %s'):format(k, v))
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
        local key, val = line:match('^([^=]+)=(.*)$')
        if key and val ~= '' then
            -- Trim leading and trailing whitespace from value
            res[key] = val:match('^%s*(.-)%s*$')
        end
    end
    f:close()

    -- Display package information
    if res.Name or res.Description then
        local info = res.Name or pkg
        if res.Description then
            info = info .. ' - ' .. res.Description
        end
        util.printout(('    %s'):format(info))
    end
    if res.Modversion then
        util.printout(('    Version: %s'):format(res.Modversion))
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
        local name = line:match('^%s*(%S+)%s*$')
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
    includedir = 'INCDIR',
    libdir = 'LIBDIR',
    prefix = 'DIR',
    bindir = 'BINDIR',
}

--- Resolve a single external dependency using pkg-config.
--- Returns new_vars on success, nil if the package is not found or an error occurs.
--- When lib names are discovered from Libs, stores them in pkginfo.pkgdep.library.
--- @param pkginfo pkginfo The pkginfo table from make_pkginfo
--- @return table? new_vars resolved variable map, or nil on failure
local function resolve_one(pkginfo)
    local pkgname, suggestions = find_package(pkginfo.name)
    if not pkgname then
        util.printout(('    %s is not registered in pkg-config.'):format(
                          pkginfo.name))
        if suggestions and #suggestions > 0 then
            util.printout(('    Did you mean: %s?'):format(concat(suggestions,
                                                                  ', ')))
        end
        return nil
    elseif pkgname ~= pkginfo.name then
        util.printout(('    resolved to %s'):format(pkgname))
    end

    local pkg_data, err = get_pkg_variables(pkgname)
    if not pkg_data then
        util.printout(('    failed to get pkg-config data: %s'):format(err or
                                                                           'unknown error'))
        return nil
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
            local lib_str = concat(lib_names, ' ')
            new_vars[pkginfo.prefix .. 'LIB'] = lib_str
            pkginfo.pkgdep.library = lib_str
        end
    end

    return new_vars
end

--- Query the linker's default library search paths.
--- Compiler-detected paths are collected first via a shell script executed once.
--- Well-known fallback paths are appended at the end for any paths not already found.
---
--- The shell script queries the linker using three complementary strategies:
---   Net 1: compiler dry-run (`cc -### -x c -`) — extracts -L flags added by the
---          compiler or from CFLAGS/LDFLAGS (effective mainly on Linux with clang/gcc).
---   Net 2: Apple ld verbose (`cc -xc - -Wl,-v -o /dev/null`) — parses the
---          "Library search paths:" block (used by both gcc and clang on macOS).
---   Net 3: GNU ld linker script (`cc -xc - -Wl,--verbose -o /dev/null`) — extracts
---          SEARCH_DIR("=/path") entries (used by both gcc and clang on Linux;
---          Apple ld rejects --verbose so this net yields nothing on macOS).
---
--- Fallback paths appended unconditionally when not already in the compiler results:
---   /usr/lib                          (standard on all platforms)
---   /usr/local/lib                    (standard on all platforms; Homebrew on Intel Mac)
---   /opt/homebrew/lib                 (Homebrew on macOS Apple Silicon)
---   /home/linuxbrew/.linuxbrew/lib    (Homebrew on Linux)
---
--- Deduplication is performed in Lua; only absolute paths not already in dirs are appended.
--- Returns at least the fallback paths even when the compiler cannot be invoked.
--- @param cc string C compiler command (e.g. from rockspec.variables.CC)
--- @return string[] dirs
local function get_compiler_libdirs(cc)
    local dirs = {}
    local seen = {}
    local function add(path)
        if path and path:match('^/') and not seen[path] then
            seen[path] = true
            dirs[#dirs + 1] = path
        end
    end

    -- Write a shell script that collects compiler-specific library paths.
    local tmpfile = os.tmpname()
    local tf = io.open(tmpfile, 'w')
    if tf then
        -- Write CC assignment first so the rest of the script can reference $CC safely.
        tf:write(('CC=%q\n'):format(cc))
        tf:write([==[
{
  # Net 1: extract -L flags from compiler dry-run (-### prints commands without executing)
  echo "int main(){}" | $CC -### -x c - 2>&1 | \
    grep -oE -- '-L(/[^ "]+)' | sed 's/^-L//'
  # Net 2: Apple ld "Library search paths:" block (macOS, both gcc and clang)
  echo "int main(){}" | $CC -xc - -Wl,-v -o /dev/null 2>&1 | \
    awk '/^Library search paths:/{f=1;next} f && /search paths:/{f=0} f && /^\t/{sub(/^\t/,""); sub(/ .*/,""); print}'
  # Net 3: GNU ld SEARCH_DIR entries (Linux, both gcc and clang)
  echo "int main(){}" | $CC -xc - -Wl,--verbose -o /dev/null 2>&1 | \
    grep -o 'SEARCH_DIR("[^"]*")' | sed 's/SEARCH_DIR("=*//' | sed 's/")//'
} 2>/dev/null
]==])
        tf:close()

        local f = io.popen('sh ' .. tmpfile)
        if f then
            for line in f:lines() do
                add(line)
            end
            f:close()
        end
        os.remove(tmpfile)
    end

    -- Append well-known fallback paths not already discovered by the compiler.
    add('/usr/lib')
    add('/usr/local/lib') -- standard; also Homebrew on Intel Mac
    add('/opt/homebrew/lib') -- Homebrew on macOS Apple Silicon
    add('/home/linuxbrew/.linuxbrew/lib') -- Homebrew on Linux

    return dirs
end

--- Query the C compiler's standard include search paths.
--- Runs `cc -xc -E -v - < /dev/null` and parses the
--- "#include <...> search starts here:" block in its output.
--- Well-known fallback paths are appended when not already discovered:
---   /usr/include                           (standard on all platforms)
---   /usr/local/include                     (standard on all platforms; Homebrew on Intel Mac)
---   /opt/homebrew/include                  (Homebrew on macOS Apple Silicon)
---   /home/linuxbrew/.linuxbrew/include     (Homebrew on Linux)
--- Path extraction per line: leading whitespace is stripped; the first absolute
--- path token (starting with /) is taken, so trailing annotations such as
--- " (framework directory)" on macOS are discarded automatically.
--- Returns the list (with at least the fallback entries) even when the
--- compiler cannot be invoked.
--- @param cc string C compiler command (e.g. from rockspec.variables.CC)
--- @return string[] dirs
local function get_compiler_incdirs(cc)
    local dirs = {}
    local seen = {}

    local f = io.popen(cc .. ' -xc -E -v - < /dev/null 2>&1')
    if f then
        local in_section = false
        for line in f:lines() do
            if not in_section then
                in_section = line:find('^#include <%.+>')
            elseif line:find('^End') then
                break
            else
                -- Strip leading whitespace and any trailing annotation
                -- (e.g. " (framework directory)" on macOS).
                local path = line:match('^%s*(/[^%s]+)')
                if path and not seen[path] then
                    seen[path] = true
                    dirs[#dirs + 1] = path
                end
            end
        end
        f:close()
    end

    -- Append well-known fallback paths not already discovered by the compiler.
    for _, d in ipairs({
        '/usr/include',
        '/usr/local/include', -- standard; also Homebrew on Intel Mac
        '/opt/homebrew/include', -- Homebrew on macOS Apple Silicon
        '/home/linuxbrew/.linuxbrew/include', -- Homebrew on Linux
    }) do
        if not seen[d] then
            seen[d] = true
            dirs[#dirs + 1] = d
        end
    end

    return dirs
end

--- Search for a library file matching the given name in a directory.
--- Checks common library naming conventions: lib?.a, lib?.so, lib?.dylib, lib?.dll.
--- @param libdir string Directory to search in
--- @param libname string Library name without "lib" prefix (e.g. "pcre2-8")
--- @return boolean
local function find_lib_in_dir(libdir, libname)
    for _, pat in ipairs({
        'lib?.a',
        'lib?.so',
        'lib?.dylib',
        'lib?.dll',
    }) do
        if fs.is_file(libdir .. '/' .. pat:gsub('%?', libname)) then
            return true
        end
    end
    return false
end

--- Set new_vars[lib_key] from library names and validate all library files.
---
--- When libdir_key is already set in new_vars, validates every library there
--- and raises an error if any is absent.
--- When libdir_key is not set, searches the compiler's default library paths
--- (from get_compiler_libdirs); sets new_vars[libdir_key] to the first directory
--- that contains all libraries. Silently leaves LIBDIR unset when neither an
--- explicit path is given nor all libraries are found together in a default path.
--- new_vars[lib_key] is set to the space-separated list of library names.
--- @param new_vars table variable map being built
--- @param libraries string[] library names (e.g. {"pcre2-8"} or {"ssl", "crypto"})
--- @param libdir_key string variable key for the library directory
--- @param lib_key string variable key for the library name
--- @param cc string|nil C compiler command from rockspec.variables.CC
local function find_libdir(new_vars, libraries, libdir_key, lib_key, cc)
    if not new_vars[lib_key] then
        new_vars[lib_key] = concat(libraries, ' ')
    end

    if new_vars[libdir_key] then
        -- Validate all libraries at the explicitly provided directory.
        for _, lib in ipairs(libraries) do
            if not find_lib_in_dir(new_vars[libdir_key], lib) then
                error(('library %q not found in %s'):format(lib,
                                                            new_vars[libdir_key]))
            end
        end
        return
    end

    -- LIBDIR not explicitly set; search the compiler's default library paths.
    if cc then
        for _, d in ipairs(get_compiler_libdirs(cc)) do
            local found_all = true
            for _, lib in ipairs(libraries) do
                if not find_lib_in_dir(d, lib) then
                    found_all = false
                    break
                end
            end
            if found_all then
                new_vars[libdir_key] = d
                return
            end
        end
    end
    -- Libraries not found in any known path; leave LIBDIR unset.
end

--- Validate header files against new_vars[incdir_key].
---
--- When incdir_key is already set in new_vars, validates every header there
--- and raises an error if any is absent.
--- When incdir_key is not set, searches the compiler's default include paths
--- (from get_compiler_incdirs); sets new_vars[incdir_key] to the first directory
--- that contains all headers. Silently leaves INCDIR unset when neither an
--- explicit path is given nor all headers are found together in a default path.
--- @param new_vars table variable map being built
--- @param headers string[] header filenames (e.g. {"pcre2.h"} or {"ssl.h", "crypto.h"})
--- @param incdir_key string variable key for the include directory
--- @param cc string|nil C compiler command from rockspec.variables.CC
local function find_incdir(new_vars, headers, incdir_key, cc)
    if new_vars[incdir_key] then
        -- Validate all headers at the explicitly provided directory.
        for _, h in ipairs(headers) do
            if not fs.is_file(new_vars[incdir_key] .. '/' .. h) then
                error(('header %q not found in %s'):format(h,
                                                           new_vars[incdir_key]))
            end
        end
        return
    end

    -- INCDIR not explicitly set; search the compiler's default include paths.
    if cc then
        for _, d in ipairs(get_compiler_incdirs(cc)) do
            local found_all = true
            for _, h in ipairs(headers) do
                if not fs.is_file(d .. '/' .. h) then
                    found_all = false
                    break
                end
            end
            if found_all then
                new_vars[incdir_key] = d
                return
            end
        end
    end
    -- Headers not found in any known path; leave INCDIR unset.
end

--- Normalize a string or string array to a string array.
--- @param v string|string[]
--- @return string[]
local function to_array(v)
    return type(v) == 'table' and v or {
        v,
    }
end

--- Format a string array for use in error messages.
--- A single-element array is formatted as a quoted string.
--- A multi-element array is formatted as {"a", "b", ...}.
--- @param v string[]
--- @return string
local function format_strlist(v)
    if #v == 1 then
        return string.format('%q', v[1])
    end
    local parts = {}
    for _, s in ipairs(v) do
        parts[#parts + 1] = string.format('%q', s)
    end
    return '{' .. concat(parts, ', ') .. '}'
end

--- Resolve a single external dependency using user-supplied directory overrides.
--- Called when pkginfo.vars is non-empty, or as a fallback when pkg-config fails.
--- Derives INCDIR/LIBDIR from DIR when not already set, then validates any
--- header or library files declared in pkginfo.pkgdep against the filesystem.
--- Returns a new_vars table.
--- Raises an error if:
---   - a required file is not found at the explicitly provided path, or
---   - the header/library is declared in pkgdep but cannot be found in any
---     default path (instructs the user to set INCDIR/LIBDIR or DIR).
--- @param pkginfo pkginfo The pkginfo table from make_pkginfo
--- @return table new_vars resolved variable map
local function resolve_args(pkginfo)
    local prefix = pkginfo.prefix
    local new_vars = {}
    for k, v in pairs(pkginfo.vars) do
        new_vars[k] = v
    end

    -- Derive INCDIR/LIBDIR from DIR if not already set.
    local dir_key = prefix .. 'DIR'
    if new_vars[dir_key] then
        if not new_vars[prefix .. 'INCDIR'] then
            new_vars[prefix .. 'INCDIR'] = new_vars[dir_key] .. '/include'
        end
        if not new_vars[prefix .. 'LIBDIR'] then
            new_vars[prefix .. 'LIBDIR'] = new_vars[dir_key] .. '/lib'
        end
    end

    local cc = pkginfo.cc
    local pkgdep = pkginfo.pkgdep
    if pkgdep.header then
        local headers = to_array(pkgdep.header)
        find_incdir(new_vars, headers, prefix .. 'INCDIR', cc)
        if not new_vars[prefix .. 'INCDIR'] then
            error(('header(s) %s not found in any default include path.\n' ..
                      'Specify %sINCDIR=<path> or %sDIR=<prefix> ' ..
                      'on the command line.'):format(format_strlist(headers),
                                                     prefix, prefix))
        end
    end
    if pkgdep.library then
        local libraries = to_array(pkgdep.library)
        find_libdir(new_vars, libraries, prefix .. 'LIBDIR', prefix .. 'LIB', cc)
        if not new_vars[prefix .. 'LIBDIR'] then
            error(('library(s) %s not found in any default library path.\n' ..
                      'Specify %sLIBDIR=<path> or %sDIR=<prefix> ' ..
                      'on the command line.'):format(format_strlist(libraries),
                                                     prefix, prefix))
        end
    end

    return new_vars
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
    elseif type(vals) == 'string' then
        vals = {
            vals,
        }
    elseif type(vals) ~= 'table' then
        error(('%s.%s: expected string or table, got %s'):format(modname, field,
                                                                 type(vals)))
    end

    local result
    for i, entry in ipairs(vals) do
        for _, suffix in ipairs({
            'LIB',
            'INCDIR',
            'LIBDIR',
        }) do
            local raw_ref = '$(' .. pkginfo.raw_prefix .. suffix .. ')'
            local norm_ref = '$(' .. pkginfo.prefix .. suffix .. ')'
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
    if type(modules) ~= 'table' then
        return pkginfo
    end

    for modname, mod in pairs(modules) do
        if type(mod) == 'table' then
            for _, field in ipairs({
                'libraries',
                'incdirs',
                'libdirs',
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
    local res = s:gsub('[^%a%d_]', '_')
    return res
end

--- @class pkginfo
--- @field name string original dep name (e.g. "LIBFOO2-8")
--- @field raw_prefix string raw uppercase prefix (e.g. "LIBFOO2-8_")
--- @field prefix string normalized prefix (e.g. "LIBFOO2_8_")
--- @field pkgdep table The pkgconfig_dependencies entry (may have header/library fields)
--- @field vars table user-supplied variables from rockspec.variables, keyed by normalized
---                   prefix (e.g. "LIBFOO2_8_DIR"). Merges variables found under raw_prefix
---                   (keys normalized) and, when raw_prefix differs from prefix, variables
---                   already stored under the normalized prefix (e.g. from the command line).
--- @field cc string|nil C compiler command from rockspec.variables.CC; used by find_incdir
---                      and find_libdir to search the compiler's default paths when INCDIR or
---                      LIBDIR are not explicitly set.
--- @field targets table modules referencing this dep's raw-form vars

--- Validate and normalize the pkgconfig_dependencies entry for a single dependency.
--- header and library fields are processed as follows:
---   - nil or absent          → left as-is (not required)
---   - string (whitespace only) → normalized to nil
---   - string (non-empty)    → left as-is
---   - table                 → empty/whitespace-only items are filtered out;
---                             if nothing remains the field is set to nil
---   - table with non-string item → raises an error
---   - any other type        → raises an error
--- @param name string dep name (for error messages)
--- @param pkgdep table pkgconfig_dependencies entry (mutated in place)
local function validate_pkgdep(name, pkgdep)
    for _, field in ipairs({
        'header',
        'library',
    }) do
        local v = pkgdep[field]
        local t = type(v)
        if t == 'string' then
            if v:find('^%s*$') then
                -- whitespace-only string: normalize to nil; treat as not specified
                pkgdep[field] = nil
            end
            -- non-empty string: OK, leave as-is
        elseif t == 'table' then
            local arr = {}
            for i, item in ipairs(v) do
                if type(item) ~= 'string' then
                    error(
                        ('pkgconfig_dependencies[%q].%s[%d]: expected string, got %s'):format(
                            name, field, i, type(item)))
                elseif not item:find('^%s*$') then
                    -- skip empty/whitespace-only strings; treat as not specified
                    arr[#arr + 1] = item
                end
            end
            pkgdep[field] = #arr > 0 and arr or nil
        elseif v ~= nil then
            error(
                ('pkgconfig_dependencies[%q].%s: expected string or array of strings, got %s'):format(
                    name, field, t))
        end
    end
end

--- Build a structured info object for a single external dependency.
--- @param rockspec table The rockspec table
--- @param name string The dependency name from pkgconfig_dependencies
--- @param pkgdep table The pkgconfig_dependencies entry (may have header/library fields)
--- @return pkginfo pkginfo
local function make_pkginfo(rockspec, name, pkgdep)
    validate_pkgdep(name, pkgdep)
    local raw_prefix = name:upper() .. '_'
    local prefix = normalize_varname(raw_prefix)

    -- Extract variables whose keys start with raw_prefix (e.g. "LIBPCRE2-8_DIR") and
    -- normalize the keys to valid identifier form (e.g. "LIBPCRE2_8_DIR").
    -- These can appear in the rockspec when the dep name is already a valid identifier,
    -- or when LuaRocks itself sets them (e.g. from a previous external_dependencies check).
    local raw_vars = extract_variables(rockspec.variables, raw_prefix)
    local vars = {}
    for k, v in pairs(raw_vars) do
        local nk = normalize_varname(k)
        if k ~= nk then
            util.printout(('    normalizing %s -> %s'):format(k, nk))
        end
        vars[nk] = v
    end

    -- When the dep name contains non-identifier characters (e.g. "LIBPCRE2-8"),
    -- raw_prefix ("LIBPCRE2-8_") is an invalid shell assignment. LuaRocks rejects
    -- "LIBPCRE2-8_DIR=..." on the command line with "Invalid assignment". Users must
    -- therefore pass the normalized form (e.g. LIBPCRE2_8_DIR=~/local). Extract those
    -- separately so that command-line overrides are honoured even when the dep name
    -- contains hyphens or dots.
    if prefix ~= raw_prefix then
        local norm_vars = extract_variables(rockspec.variables, prefix)
        for k, v in pairs(norm_vars) do
            vars[k] = v
        end
    end

    return get_target_modules(rockspec, {
        name = name,
        raw_prefix = raw_prefix,
        prefix = prefix,
        pkgdep = pkgdep,
        vars = vars,
        cc = rockspec.variables and rockspec.variables.CC,
        targets = {},
    })
end

--- Resolve dependencies using pkg-config or user-supplied directory overrides.
--- Reads build.pkgconfig_dependencies; does nothing if the table is absent.
---
--- For each dependency:
---  1. If the user provided no override variables → try pkg-config (resolve_one).
---  2. If pkg-config is unavailable or the package is not found → fall back to
---     resolve_args, which validates files against the filesystem using the
---     pkgdep.header / pkgdep.library fields.
---  3. If the user did provide override variables → resolve_args is called directly.
---
--- @param rockspec table The rockspec table
local function resolve_pkgconfig(rockspec)
    local pkgdeps = rockspec.build and rockspec.build.pkgconfig_dependencies
    if not pkgdeps then
        return
    end

    util.printout('hooks.pkgconfig: resolving external dependencies...')
    for name, pkgdep in pairs(pkgdeps) do
        util.printout(('  checking %s ...'):format(name))
        local pkginfo = make_pkginfo(rockspec, name, pkgdep)
        local res
        if not next(pkginfo.vars) then
            res = resolve_one(pkginfo)
        end
        if not res then
            res = resolve_args(pkginfo)
        end
        update_variables(rockspec.variables, res, pkginfo.vars)
        expand_lib_vars(pkginfo.targets, pkginfo)
    end
end

return resolve_pkgconfig
