# luarocks-build-hooks

[![test](https://github.com/mah0x211/luarocks-build-hooks/actions/workflows/test.yml/badge.svg)](https://github.com/mah0x211/luarocks-build-hooks/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/mah0x211/luarocks-build-hooks/branch/master/graph/badge.svg)](https://codecov.io/gh/mah0x211/luarocks-build-hooks)


A custom build backend for LuaRocks that extends the standard `builtin` backend with support for executing Lua scripts before and after the build process.


## Requirements

- Lua 5.1 or later
- LuaRocks 3.0 or later (recommended for `build_dependencies` support)


## Installation

```bash
luarocks install luarocks-build-hooks
```


## Usage

Utilize `build_dependencies` to ensure this backend is available during the build process, and specify `build.type = "hooks"` in your rockspec.


### Example Rockspec

```lua
rockspec_format = "3.0"
package = "my-package"
version = "1.0-1"

-- Add this module to build_dependencies
build_dependencies = {
   "luarocks-build-hooks"
}

build = {
   type = "hooks",
   -- Standard builtin modules definition
   modules = {
      ["my.module"] = "src/my/module.lua"
   },

   -- Hook configuration
   -- before_build: Runs before the builtin build process starts
   before_build = "scripts/preprocess.lua",

   -- after_build: Runs after the builtin build process finishes
   after_build = "scripts/cleanup.lua"
}
```

### Multiple Hooks

You can specify multiple hooks as an array. They will be executed in order.

```lua
build = {
   type = "hooks",

   -- Multiple hooks executed in order
   before_build = {
      "scripts/generate_headers.lua",
      "scripts/prepare_assets.lua",
      "$(pkgconfig)",  -- Built-in hooks can also be used in arrays
   },

   after_build = {
      "scripts/cleanup_temp.lua",
      "scripts/postprocess.lua",
   },
}
```


### Hooks with Arguments

You can pass arguments to hook scripts by adding them after the script path.

```lua
build = {
   type = "hooks",

   -- Hook with arguments
   before_build = "scripts/generate.lua --verbose --output=dist",

   -- Built-in hook with arguments
   after_build = "$(my-custom-hook) arg1 arg2",
}
```

The hook script receives the `rockspec` as the first argument, followed by any additional arguments:

```lua
-- scripts/generate.lua
local rockspec, verbose, output_option = ...

if verbose == "--verbose" then
   print("Verbose mode enabled")
end

-- Process arguments...
```


## Configuration Fields

- `build.type`: Must be set to `"hooks"`.
- `build.before_build` (optional): Path to a Lua script to execute before the build, or an array of hook strings.
- `build.after_build` (optional): Path to a Lua script to execute after the build, or an array of hook strings.

**Hook String Format:**

- `"<path>"` - Execute script at `<path>`
- `"<path> <arg1> <arg2> ..."` - Execute script with arguments
- `"$(hook_name)"` - Execute built-in hook
- `"$(hook_name) <arg1> <arg2> ..."` - Execute built-in hook with arguments


## Hook Scripts

Hooks must be Lua scripts. They are executed in a sandboxed environment within the same Lua VM.

The `rockspec` table is passed as the first argument to the script, followed by any additional arguments specified in the hook string.

**Example `scripts/preprocess.lua`**:

```lua
local rockspec = ...

print("Running pre-processing...")
-- You can modify the rockspec table
rockspec.variables.MY_CUSTOM_VAR = "some_value"

local f = io.open("src/generated_code.lua", "w")
f:write("return { generated = true }")
f:close()
```


## Built-in Hooks

Built-in hooks are predefined hooks that can be invoked using the `$(hook_name)` syntax in your `before_build` or `after_build` fields. These hooks provide common functionality without requiring you to write custom scripts.

**Syntax to use a built-in hook:**

```lua
build = {
    type = "hooks",
    before_build = "$(hook_name)",
    -- or
    after_build = "$(hook_name)",
}
```


## `$(pkgconfig)` Built-in Hook

The `pkgconfig` hook resolves external C library dependencies and populates LuaRocks variables with the correct include and library paths. It uses `pkg-config` when available, and falls back to searching the compiler's default paths when it is not.

Using `pkgconfig_dependencies` instead of `external_dependencies` is intentional: LuaRocks validates `external_dependencies` before any hook runs, which would cause the build to fail before the hook has a chance to resolve paths. By declaring dependencies in `pkgconfig_dependencies`, resolution is deferred to the hook itself.

**Resolution Flow:**

For each entry in `build.pkgconfig_dependencies`:

1. **No user overrides supplied** — the hook tries to resolve the package via `pkg-config`. Variables such as `INCDIR`, `LIBDIR`, and `LIB` are populated from the `.pc` file.
2. **`pkg-config` is unavailable or the package is not registered** — the hook searches the compiler's default include and library paths for the declared `header` and `library` files, and sets `INCDIR`/`LIBDIR` to the first directory where all declared files are found together.
3. **User supplies `PKG_DIR`, `PKG_INCDIR`, or `PKG_LIBDIR`** — the hook uses those values directly and validates that every declared header and library file is present at the specified path.

If a required file cannot be located in any searched path, the hook raises an error with a hint on which variable to set.

**`pkgconfig_dependencies` Schema:**

```lua
build = {
    type = "hooks",
    before_build = "$(pkgconfig)",
    pkgconfig_dependencies = {
        -- Key: dependency name matching the pkg-config package name
        --      (case-insensitive). Non-identifier characters (hyphens, dots)
        --      are normalized to underscores in LuaRocks variable names.
        ["LIBPCRE2-8"] = {
            -- header: header filename(s) to locate. A string or an array of
            --         strings. All listed files must exist in the same
            --         directory. Used to discover and validate INCDIR.
            header = "pcre2.h",           -- or { "pcre2.h", "pcre2posix.h" }

            -- library: library name(s) without the "lib" prefix. A string or
            --          an array of strings. All listed libraries must exist in
            --          the same directory. Used to discover and validate LIBDIR
            --          and to set the LIB variable.
            library = "pcre2-8",          -- or { "pcre2-8", "pcre2-posix" }
        },
    },
    ...
}
```

Both `header` and `library` are optional. If omitted, path discovery for that side is skipped (the hook only populates variables from `pkg-config`).

**User Directory Overrides:**

You can override paths on the command line using the normalized variable name (hyphens and dots replaced with underscores):

```bash
# Provide a prefix; INCDIR and LIBDIR are derived as <prefix>/include and <prefix>/lib
luarocks make LIBPCRE2_8_DIR=~/local

# Or set INCDIR and LIBDIR directly
luarocks make LIBPCRE2_8_INCDIR=~/local/include LIBPCRE2_8_LIBDIR=~/local/lib
```

The hook validates that every declared `header` and `library` file actually exists at the given path and raises an error if any file is missing.

**Compatibility:**

The hook invokes `pkg-config` using the following options. All of these are supported by `pkgconf` with identical behavior, so the hook works transparently on systems where `pkg-config` is provided as a symlink to `pkgconf` (the default on Debian/Ubuntu and most modern Linux distributions):

| Option | Purpose |
|--------|---------|
| `--variable=pcfiledir <pkg>` | Locate the directory containing the `.pc` file |
| `--variable=<name> <pkg>` | Read an individual variable value from the `.pc` file |
| `--libs <pkg>` | Get linker flags (e.g., `-L/path/lib -lfoo`) |
| `--cflags <pkg>` | Get compiler flags (e.g., `-I/path/include`) |
| `--modversion <pkg>` | Get the package module version |
| `--list-all` | Enumerate all packages known to `pkg-config` |

If only `pkgconf` is installed without a `pkg-config` symlink, the hook will fail to find the command. In that case, create the symlink manually or install the `pkg-config` compatibility package for your distribution.

**Variable Mapping:**

When `pkg-config` resolves a package, the hook maps its variables and metadata to LuaRocks variables as follows:
- `includedir` → `<PACKAGE>_INCDIR`
- `libdir` → `<PACKAGE>_LIBDIR`
- `prefix` → `<PACKAGE>_DIR`
- `bindir` → `<PACKAGE>_BINDIR`
- Other variables → `<PACKAGE>_<VARNAME>` (uppercase)
- Version (from `Version:` field) → `<PACKAGE>_VERSION`
- Modversion (from `--modversion`) → `<PACKAGE>_MODVERSION`
- Libs (from `--libs`) → `<PACKAGE>_LIBS`
- Cflags (from `--cflags`) → `<PACKAGE>_CFLAGS`
- Library names (from `--libs`, without `-l` prefix, space-separated) → `<PACKAGE>_LIB`

For example, `LIBPCRE2-8` in `pkgconfig_dependencies` produces variables such as:

- `LIBPCRE2_8_INCDIR`
- `LIBPCRE2_8_LIBDIR`
- `LIBPCRE2_8_DIR`
- `LIBPCRE2_8_VERSION`
- `LIBPCRE2_8_MODVERSION`
- `LIBPCRE2_8_LIBS` (e.g., `-lpcre2-8`)
- `LIBPCRE2_8_LIB` (e.g., `pcre2-8`)
- `LIBPCRE2_8_CFLAGS`
- etc.

**Hyphen and Dot Normalization:**

LuaRocks variable substitution (`$(NAME)`) only recognizes names that start with a letter and contain only letters, digits, and underscores. `pkgconfig_dependencies` key names can contain hyphens and dots to match `pkg-config` package names (e.g., `libfoo-2.0`).

The hook normalizes all non-identifier characters to underscores when generating LuaRocks variable names.

For example, `libfoo-2.0` in `pkgconfig_dependencies` produces:

- `LIBFOO_2_0_INCDIR` (not `LIBFOO-2.0_INCDIR`)
- `LIBFOO_2_0_LIBDIR`
- `LIBFOO_2_0_LIB`
- etc.

Use the normalized form when referencing these variables in your rockspec (e.g., `$(LIBFOO_2_0_INCDIR)`). Use the same normalized form for command-line overrides (e.g., `LIBFOO_2_0_DIR=~/local`).

**Using `$(PACKAGE_LIB)` in the `libraries` field:**

The `<PACKAGE>_LIB` variable contains the library names without the `-l` prefix and without linker flags like `-L`. This lets you use `$(PACKAGE_LIB)` directly in the `libraries` field.

For packages with a **single library**, the hook leaves `$(PACKAGE_LIB)` as-is. LuaRocks substitutes the variable and prepends `-l` automatically.

For packages with **multiple libraries** (e.g., `bar` provides `-lbar -lbaz`), the hook **expands** the `libraries` entry before `builtin.run()` processes it. A single `"$(BAR_LIB)"` entry is replaced with individual library name strings `{"bar", "baz"}`, which LuaRocks then maps to `-lbar -lbaz`.

> **Note:** Embedding `$(PACKAGE_LIB)` inside a larger string (e.g., `"extra_$(BAR_LIB)"`) raises an error when the package provides multiple libraries, since the expansion cannot be represented as a single library name.

**Usage Example:**

```lua
rockspec_format = "3.0"
package = "mypackage"
version = "1.0-1"

build_dependencies = {
    "luarocks-build-hooks",
}

-- Keep this as an explicit empty table to suppress LuaRocks'
-- external dependency autodetection from build.modules.
external_dependencies = {}

build = {
    type = "hooks",
    before_build = "$(pkgconfig)",

    -- Declare C library dependencies here instead of external_dependencies.
    -- pkg-config resolves paths automatically; compiler default paths are
    -- searched as a fallback; user can override with LIBPCRE2_8_DIR=... etc.
    pkgconfig_dependencies = {
        ["LIBPCRE2-8"] = {
            header  = "pcre2.h",
            library = "pcre2-8",
        },
    },

    modules = {
        mymodule = {
            sources   = { "src/mymodule.c" },
            libraries = { "$(LIBPCRE2_8_LIB)" },
            incdirs   = { "$(LIBPCRE2_8_INCDIR)" },
            libdirs   = { "$(LIBPCRE2_8_LIBDIR)" },
        },
    },
}
```

**Notes:**

- The dependency name in `pkgconfig_dependencies` should match the `pkg-config` package name (case-insensitive).
- Variable names are automatically uppercased and any non-identifier character is replaced with an underscore (e.g., `libfoo-2.0` → `LIBFOO_2_0_*`), as required by LuaRocks `$(NAME)` substitution.
- When `build.modules` references hook-generated variables such as `$(LIBFOO_2_0_LIB)`, keep `external_dependencies = {}` in the rockspec to suppress LuaRocks' pre-hook autodetection.
- If a package is not found by `pkg-config`, the hook logs a message and falls back to compiler default path search.
- If a package is not found, the hook suggests similar package names based on `pkg-config --list-all`.
- If `header` or `library` is declared but cannot be found in any path, the hook raises an error with a hint on which variable to set.
- All variables from the `.pc` file are made available, not just the standard ones.


## `$(extra-vars)` Built-in Hook

The `extra-vars` hook allows you to append additional values to existing `rockspec.variables`. This is useful when you want to extend build variables (such as `CFLAGS`, `LIBFLAG`, etc.) with custom values without completely replacing them.

**How it works:**

1. Reads `build.extra_variables` from your rockspec
2. For each entry, validates the value (string or array of strings)
3. Appends the value to the corresponding variable in `rockspec.variables` if it exists and is a non-empty string
4. Skips variables that don't exist, are not strings, or are empty

**Usage Example:**

```lua
build = {
    type = "hooks",
    before_build = "$(extra-vars)",

    -- Define variables that will receive extra values
    variables = {
        CFLAGS = "-O2",
        LIBFLAG = "-shared",
    },

    -- Extra values to append to existing variables
    extra_variables = {
        -- Append a single string
        CFLAGS = "-Wall -Wextra",

        -- Append an array of strings (joined with spaces)
        LIBFLAG = {"-fPIC", "-static"},
    },
}
```

After the hook runs:

- `rockspec.variables.CFLAGS` becomes `-O2 -Wall -Wextra`
- `rockspec.variables.LIBFLAG` becomes `-shared -fPIC -static`

**Value Types:**

You can specify extra values as:

- **String:** `CFLAGS = "-Wall"` → appends `-Wall`
- **Array of strings:** `CFLAGS = {"-Wall", "-Wextra"}` → appends `-Wall -Wextra`

**Behavior:**

- Whitespace is automatically trimmed from values
- Empty strings in arrays are filtered out
- Only appends to existing **non-empty string** variables in `rockspec.variables`
- Skips variables that:
  - Don't exist in `rockspec.variables`
  - Are not strings (e.g., numbers, tables)
  - Are empty strings

**Example with mixed results:**

```lua
variables = {
    CFLAGS = "-O2",           -- Will be extended
    LIBFLAG = "",             -- Empty: will be skipped
    LDFLAGS = 123,            -- Not a string: will be skipped
    -- NONEXISTENT is not defined: will be skipped
}
build = {
    type = "hooks",
    before_build = "$(extra-vars)",
    extra_variables = {
        CFLAGS = "-Wall",         -- Appended: CFLAGS becomes "-O2 -Wall"
        LIBFLAG = "-static",      -- Skipped (LIBFLAG is empty)
        LDFLAGS = "-Wl,--as-needed",  -- Skipped (LDFLAGS is not a string)
        NONEXISTENT = "--unused", -- Skipped (variable doesn't exist)
    }
    ...
}
```

**Error Handling:**

The hook will raise an error if:
- `build.extra_variables` is not a table
- A variable name in `extra_variables` is not a string
- A value is neither a string nor an array of strings


### Conditional Variables

The `extra-vars` hook also supports `conditional_variables`, which allows you to append variables only when a specific flag is enabled. This is useful for feature toggles, debug builds, or platform-specific configurations.

**Configuration:**

You can define `conditional_variables` in the `build` table. The keys are the flag names (variables in `rockspec.variables`), and the values are tables of variables to append if the flag is enabled.

```lua
build = {
    type = "hooks",
    before_build = "$(extra-vars)",
    conditional_variables = {
        -- Appends -DDEBUG -g to CFLAGS only if ENABLE_DEBUG environment variable is defined as considered enabled
        ENABLE_DEBUG = {
            CFLAGS = "-DDEBUG -g",
        },
        -- Appends --coverage to CFLAGS and LIBFLAG only if ENABLE_COVERAGE environment variable is defined as considered enabled
        ENABLE_COVERAGE = {
            CFLAGS = "--coverage",
            LIBFLAG = "--coverage",
        }
    }
}
```

**Boolean Logic:**

A flag is considered **enabled** if the value of the corresponding **environment variable** matches one of the following:

- `1`
- `true` (Boolean type)

A flag is considered **disabled** if its value is any other string or value.

**Execution Order:**

1. `extra_variables` are processed first (Unconditional).
2. `conditional_variables` are processed second (Conditional).

This means conditional values are appended *after* any unconditional extra values.

**Usage with LuaRocks:**

You can facilitate these flags from the command line by setting environment variables:

```bash
# Enable debug mode
ENABLE_DEBUG=1 luarocks make

# Disable debug mode
ENABLE_DEBUG=0 luarocks make

# Empty string is disabled
ENABLE_FEATURE= luarocks make
```


## License

MIT/X11
