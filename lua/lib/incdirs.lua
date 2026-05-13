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
local pkginfo = require('luarocks.build.hooks.lib.pkginfo')

--- Removes double slashes and trailing slash from a path.
local function normalize_path(path)
    return path:gsub('//+', '/'):gsub('/$', '')
end

--- Return the include directories for the currently installed version of a package. The include directories are determined by looking for header files in the conf directory of the package, since that's where the header files are usually installed. If no header files are found in the conf directory, it means the package has no include directories.
--- @param pkgname string The name of the package to get the include directories for.
--- @param constraints table? Optional constraints for the package version.
--- @return table? dirs A table containing the include directories for the package, structured as { headers = {header1, header2, ...}, dirnames = {dir1, dir2, ...} }. If the package has no include directories, this will be nil.
--- @return any err An error message if the include directories could not be retrieved. if dirs and err are both nil, it means the package was not found or has no include directories.
local function incdirs(pkgname, constraints)
    local info, err = pkginfo(pkgname, constraints)
    if not info then
        return nil, err
    end

    local confdir = normalize_path(info.dir.conf)
    local nodup = {}
    local dirs = {}
    local files = {}
    for pathname in pairs(info.manifest.conf or {}) do
        -- found a header file in the manifest
        local filename = pathname:match('([^/]+%.h)$')
        if filename then
            -- extract dirname from pathname
            local dirname = pathname:match('^(.*)/[^/]*$')
            if dirname then
                dirname = confdir .. '/' .. normalize_path(dirname)
            else
                -- the header file is in the root of the conf directory
                dirname = confdir
            end

            if not nodup[dirname] then
                nodup[dirname] = true
                dirs[#dirs + 1] = dirname
            end

            if not nodup[pathname] then
                nodup[pathname] = dirname
                files[#files + 1] = filename
            end
        end
    end

    -- found header files in the manifest, return the include directories
    if #dirs > 0 then
        return {
            headers = files,
            incdirs = dirs,
        }
    end
end

return incdirs
