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
local new_queries = require('luarocks.queries').new
local pick_installed_rock = require('luarocks.search').pick_installed_rock
local load_manifest = require('luarocks.manif').load_rock_manifest
local path = require('luarocks.path')

--- @class luarocks.build.hooks.pkginfo.dir
--- @field bin string The directory for binary files.
--- @field lua string The directory for Lua files.
--- @field lib string The directory for library files.
--- @field doc string The directory for documentation files.
--- @field conf string The directory for configuration files.
--- @field versions string The directory for version files.
--- @field install string The directory for installation files.

--- @class luarocks.build.hooks.pkginfo.file
--- @field rock_manifest string The path to the rock manifest file.
--- @field rockspec string The path to the rockspec file.
--- @field rock_namespace string The path to the rock namespace file.

--- @class luarocks.build.hooks.pkginfo
--- @field name string The name of the package.
--- @field version string The version of the package.
--- @field tree string The tree where the package is installed.
--- @field dir luarocks.build.hooks.pkginfo.dir The directories of the package.
--- @field file luarocks.build.hooks.pkginfo.file The files of the package.
--- @field namespace string? The namespace of the package, if any.
--- @field manifest table The rock manifest of the package. loaded from the rock manifest file.

--- Return the package information for the currently installed version of a package.
--- @param pkgname string The name of the package to get the information for.
--- @param constraints table? Optional constraints for the package version.
--- @return luarocks.build.hooks.pkginfo? pkginfo
--- @return any err An error message if the package information could not be retrieved. if pkginfo and err are both nil, it means the package was not found.
local function pkginfo(pkgname, constraints)
    assert(type(pkgname) == 'string', 'pkgname must be a string')
    assert(constraints == nil or type(constraints) == 'table',
           'constraints must be a table if provided')

    -- Create a query for the given package name and constraints
    local query = new_queries(pkgname, nil, nil, false)
    query.constraints = constraints or query.constraints
    -- Pick the installed rock that best matches the query
    local name, version, tree = pick_installed_rock(query,
                                                    path.root_from_rocks_dir(
                                                        path.rocks_dir()))
    if not name then
        -- No installed rock found for the given package name.
        return
    end

    local rock_manifest, err = load_manifest(name, version, tree)
    if not rock_manifest then
        -- Failed to load the rock manifest for the found package.
        return nil, err
    end

    return {
        name = name,
        version = version,
        tree = tree,
        manifest = rock_manifest,
        dir = {
            bin = path.bin_dir(name, version, tree),
            lua = path.lua_dir(name, version, tree),
            lib = path.lib_dir(name, version, tree),
            doc = path.doc_dir(name, version, tree),
            conf = path.conf_dir(name, version, tree),
            versions = path.versions_dir(name, tree),
            install = path.install_dir(name, version, tree),
        },
        file = {
            rock_manifest = path.rock_manifest_file(name, version, tree),
            rockspec = path.rockspec_file(name, version, tree),
            rock_namespace = path.rock_namespace_file(name, version, tree),
        },
        namespace = path.read_namespace(name, version, tree),
    }
end

return pkginfo
