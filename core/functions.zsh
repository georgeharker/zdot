#!/usr/bin/env zsh
# zsh-base/functions: Function autoloading system
# Provides helpers for autoloading functions from module and global directories

# ============================================================================
# Function Management
# ============================================================================

# Compile all files matching a glob in a directory to co-located .zwc files.
# Usage: zdot_cache_compile_functions <func-dir> [glob-pattern]
# glob-pattern defaults to * (all files); .zwc files are always skipped.
# Returns: 0 on success, 1 on error
zdot_cache_compile_functions() {
    local func_dir="$1"
    local glob="${2:-*}"

    if [[ -z "$func_dir" ]]; then
        zdot_error "zdot_cache_compile_functions: function directory required"
        return 1
    fi

    if [[ ! -d "$func_dir" ]]; then
        return 0
    fi

    # Compile each matching file to .zwc next to the source
    local failed=0
    for func_file in "$func_dir"/$~glob(N); do
        [[ -f "$func_file" ]] || continue
        # Skip .zwc files themselves
        [[ "$func_file" == *.zwc ]] && continue
        local cache_path="${func_file}.zwc"

        # Compile if needed (source newer than cache or cache doesn't exist)
        if zdot_is_newer_or_missing "$func_file" "$cache_path"; then
            if ! zcompile "$cache_path" "$func_file" 2>/dev/null; then
                zdot_error "zdot_cache_compile_functions: compilation failed for: $func_file"
                failed=1
            fi
        fi
    done

    return $failed
}

# Add a directory to fpath and compile its contents.
# Usage: zdot_add_fpath <dir> [--glob <pattern>]
#
# Prepends <dir> to fpath so zsh can find autoloaded functions and completions.
# If caching is enabled, compiles files matching <pattern> (default: *) to
# co-located .zwc files. .zwc files are always excluded from compilation.
#
# Options:
#   --glob <pattern>   Glob pattern for files to compile (default: *)
#                      Use *.zsh to restrict to zsh files, or *.zsh *.sh to
#                      include both. Applied with zsh (N) null-glob flag.
zdot_add_fpath() {
    local dir="$1"
    local glob="*"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --glob) glob="$2"; shift 2 ;;
            *) zdot_error "zdot_add_fpath: unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$dir" ]]; then
        zdot_error "zdot_add_fpath: directory required"
        return 1
    fi

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    # Prepend to fpath so zsh finds functions and completions here
    fpath=("$dir" $fpath)

    # Compile matching files if caching is enabled
    if zdot_cache_is_enabled; then
        zdot_cache_compile_functions "$dir" "$glob"
    fi
}

# Source a file or all matching files in a directory, compiling each first.
# Usage: zdot_include_source <path> [--glob <pattern>]
#
# If <path> is a file:      compile (if cache enabled) + source it.
# If <path> is a directory: compile + source all files matching <pattern>.
#
# Options:
#   --glob <pattern>   Glob pattern when <path> is a directory (default: *.zsh)
#                      Applied with zsh (N) null-glob flag; .zwc always excluded.
#
# Note: no module context vars are set. This is a plain public include,
# not a module loader. For module-relative sourcing use zdot_module_source.
zdot_include_source() {
    local path="$1"
    local glob="*.zsh"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --glob) glob="$2"; shift 2 ;;
            *) zdot_error "zdot_include_source: unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$path" ]]; then
        zdot_error "zdot_include_source: path required"
        return 1
    fi

    if [[ -f "$path" ]]; then
        # Single file mode — --glob is ignored
        [[ "$path" == *.zwc ]] && return 0
        if zdot_cache_is_enabled; then
            zdot_cache_compile_file "$path"
        fi
        source "$path"
        return
    fi

    if [[ -d "$path" ]]; then
        # Directory mode — source all files matching glob
        local f
        for f in "$path"/$~glob(N); do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.zwc ]] && continue
            if zdot_cache_is_enabled; then
                zdot_cache_compile_file "$f"
            fi
            source "$f"
        done
        return
    fi

    zdot_error "zdot_include_source: not a file or directory: $path"
    return 1
}

# Autoload functions from the calling module's functions directory
# Only supports individual function files (one function per file)
# Usage: zdot_module_autoload_funcs [function-names...]
#
# If no arguments: autoloads all files in module's functions/ directory
# If arguments: autoloads only specified function names
#
# Note: Functions are lazy loaded (registered with autoload -Uz)
# They will only be sourced when first called.
zdot_module_autoload_funcs() {
    zdot_module_dir
    local module_dir="$REPLY"
    local func_dir="${module_dir}/functions"

    if [[ ! -d "$func_dir" ]]; then
        return 0
    fi

    # Add to fpath and compile (delegates shared logic to zdot_add_fpath)
    zdot_add_fpath "$func_dir"

    if [[ $# -eq 0 ]]; then
        # Autoload all function files
        for func_file in "$func_dir"/*; do
            [[ -f "$func_file" ]] || continue
            local func_name="${func_file:t}"
            # Skip completion functions (_*) — compinit discovers them via fpath
            [[ "$func_name" == _* ]] && continue

            # Individual function file - autoload it
            autoload -Uz "$func_name"
        done
    else
        # Autoload specified functions
        autoload -Uz "$@"
    fi
}

# Autoload functions from the global functions directory
# Only supports individual function files (one function per file)
# Usage: zdot_autoload_global_funcs [function-names...]
#
# Note: Functions are lazy loaded (registered with autoload -Uz)
# They will only be sourced when first called.
zdot_autoload_global_funcs() {
    _zdot_functions_dir
    local functions_dir="$REPLY"

    if [[ ! -d "$functions_dir" ]]; then
        return 0
    fi

    # Add to fpath and compile (delegates shared logic to zdot_add_fpath)
    zdot_add_fpath "$functions_dir"

    if [[ $# -eq 0 ]]; then
        # Autoload all function files
        for func_file in "$functions_dir"/*; do
            [[ -f "$func_file" ]] || continue
            local func_name="${func_file:t}"
            # Skip completion functions (_*) — compinit discovers them via fpath
            [[ "$func_name" == _* ]] && continue

            # Individual function file - autoload it
            autoload -Uz "$func_name"
        done
    else
        # Autoload specified functions
        autoload -Uz "$@"
    fi
}
