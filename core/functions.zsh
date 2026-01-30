#!/usr/bin/env zsh
# zsh-base/functions: Function autoloading system
# Provides helpers for autoloading functions from module and global directories

# ============================================================================
# Function Management
# ============================================================================

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

    # Add functions directory to fpath
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

    # Add global functions directory to fpath
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
