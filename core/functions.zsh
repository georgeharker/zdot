#!/usr/bin/env zsh
# zsh-base/functions: Function autoloading system
# Provides helpers for autoloading functions from module and global directories

# ============================================================================
# Function Management
# ============================================================================

# Compile all functions in a directory to .zwc files (co-located with source)
# Usage: zdot_cache_compile_functions <func-dir>
# Returns: 0 on success, 1 on error
zdot_cache_compile_functions() {
    local func_dir="$1"

    if [[ -z "$func_dir" ]]; then
        zdot_error "zdot_cache_compile_functions: function directory required"
        return 1
    fi

    if [[ ! -d "$func_dir" ]]; then
        return 0
    fi

    # Compile each function file to .zwc next to the source
    local failed=0
    for func_file in "$func_dir"/*; do
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
    local module_dir=$(zdot_module_dir)
    local func_dir="${module_dir}/functions"

    if [[ ! -d "$func_dir" ]]; then
        return 0
    fi

    # Compile functions if caching is enabled
    if zdot_cache_is_enabled; then
        zdot_cache_compile_functions "$func_dir"
    fi

    # Always add source directory to fpath (with co-located .zwc files)
    fpath=("$func_dir" $fpath)

    if [[ $# -eq 0 ]]; then
        # Autoload all function files
        for func_file in "$func_dir"/*; do
            [[ -f "$func_file" ]] || continue
            local func_name="${func_file:t}"

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
    local functions_dir="$(_zdot_functions_dir)"

    if [[ ! -d "$functions_dir" ]]; then
        return 0
    fi

    # Compile functions if caching is enabled
    if zdot_cache_is_enabled; then
        zdot_cache_compile_functions "$functions_dir"
    fi

    # Always add source directory to fpath (with co-located .zwc files)
    fpath=("$functions_dir" $fpath)

    if [[ $# -eq 0 ]]; then
        # Autoload all function files
        for func_file in "$functions_dir"/*; do
            [[ -f "$func_file" ]] || continue
            local func_name="${func_file:t}"

            # Individual function file - autoload it
            autoload -Uz "$func_name"
        done
    else
        # Autoload specified functions
        autoload -Uz "$@"
    fi
}
