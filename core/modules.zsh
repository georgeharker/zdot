#!/usr/bin/env zsh
# zsh-base/modules: Module discovery and loading system
# Provides module lifecycle management

# ============================================================================
# Module Loading
# ============================================================================

# Get the directory of the calling module
# Usage: local mydir=$(zdot_module_dir)
# Must be called from within a module file
# Uses _ZDOT_CURRENT_MODULE_DIR if set (during module loading)
zdot_module_dir() {
    if [[ -n "$_ZDOT_CURRENT_MODULE_DIR" ]]; then
        echo "$_ZDOT_CURRENT_MODULE_DIR"
    else
        # Fallback: Use ${(%):-%x} to get the path of the sourced file
        local module_file="${${(%):-%x}:A}"
        echo "${module_file:h}"
    fi
}

# Get the path to a module's main file
# Usage: zdot_module_path <module-name>
zdot_module_path() {
    local module="$1"

    if [[ -z "$module" ]]; then
        zdot_error "zdot_module_path: module name required"
        return 1
    fi

    echo "${_ZDOT_LIB_DIR}/${module}/${module}.zsh"
}

# Internal: load a module from an explicit file path.
# Handles dedup, existence check, source/cache, marks _ZDOT_MODULES_LOADED.
# Extra tracking arrays (e.g. _ZDOT_USER_MODULES_LOADED) are the caller's responsibility.
# Usage: _zdot_load_module_file <module-name> <module-file>
_zdot_load_module_file() {
    local module="$1" module_file="$2"
    [[ -n "${_ZDOT_MODULES_LOADED[$module]}" ]] && return 0
    if [[ ! -f "$module_file" ]]; then
        zdot_error "_zdot_load_module_file: module file not found: $module_file"
        return 1
    fi
    _zdot_source_module "$module" "$module_file"
    _ZDOT_MODULES_LOADED[$module]=1
}

# Load a module by name
# Usage: zdot_module_load <module-name>
zdot_module_load() {
    local module="$1"
    [[ -z "$module" ]] && { zdot_error "zdot_module_load: module name required"; return 1 }
    _zdot_load_module_file "$module" "${_ZDOT_LIB_DIR}/${module}/${module}.zsh"
}

# List all loaded modules
# Usage: zdot_module_list
zdot_module_list() {
    zdot_report "Loaded modules:"
    for module in ${(k)_ZDOT_MODULES_LOADED}; do
        zdot_info "  $module"
    done
}

# ============================================================================
# User Module Loading
# ============================================================================

# Resolve the user modules directory from zstyle or cached global
# Usage: _zdot_user_modules_dir
# Prints the directory path, or prints nothing and returns 1 if unset
_zdot_user_modules_dir() {
    if [[ -n "$_ZDOT_USER_MODULES_DIR" ]]; then
        echo "$_ZDOT_USER_MODULES_DIR"
        return 0
    fi

    local dir
    zstyle -s ':zdot:user-modules' path dir
    if [[ -n "$dir" ]]; then
        dir="${~dir}"
        _ZDOT_USER_MODULES_DIR="$dir"
        echo "$dir"
        return 0
    fi

    return 1
}

# Get the path to a user module's main file
# Usage: zdot_user_module_path <module-name>
zdot_user_module_path() {
    local module="$1"

    if [[ -z "$module" ]]; then
        zdot_error "zdot_user_module_path: module name required"
        return 1
    fi

    local user_dir
    if ! user_dir="$(_zdot_user_modules_dir)"; then
        zdot_error "zdot_user_module_path: user modules directory not configured (zstyle ':zdot:user-modules' path <dir>)"
        return 1
    fi

    echo "${user_dir}/${module}/${module}.zsh"
}

# Load a user module by name
# Usage: zdot_user_module_load <module-name>
zdot_user_module_load() {
    local module="$1"
    [[ -z "$module" ]] && { zdot_error "zdot_user_module_load: module name required"; return 1 }
    local user_dir
    if ! user_dir="$(_zdot_user_modules_dir)"; then
        zdot_error "zdot_user_module_load: user modules directory not configured (zstyle ':zdot:user-modules' path <dir>)"
        return 1
    fi
    _zdot_load_module_file "$module" "${user_dir}/${module}/${module}.zsh" || return 1
    _ZDOT_USER_MODULES_LOADED[$module]=1
}

# List all loaded user modules
# Usage: zdot_user_module_list
zdot_user_module_list() {
    if [[ ${#_ZDOT_USER_MODULES_LOADED} -eq 0 ]]; then
        zdot_info "No user modules loaded."
        return 0
    fi
    zdot_report "Loaded user modules:"
    for module in ${(k)_ZDOT_USER_MODULES_LOADED}; do
        zdot_info "  $module"
    done
}
