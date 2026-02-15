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

# Load a module by name
# Usage: zdot_module_load <module-name>
zdot_module_load() {
    local module="$1"

    if [[ -z "$module" ]]; then
        zdot_error "zdot_module_load: module name required"
        return 1
    fi

    # Check if already loaded
    if [[ -n "${_ZDOT_MODULES_LOADED[$module]}" ]]; then
        return 0
    fi

    local module_file=$(zdot_module_path "$module")

    if [[ ! -f "$module_file" ]]; then
        zdot_error "zdot_module_load: module file not found: $module_file"
        return 1
    fi

    # Set the module directory and name for the module being loaded
    _ZDOT_CURRENT_MODULE_DIR="${module_file:h}"
    _ZDOT_CURRENT_MODULE_NAME="$module"

    source "$module_file"
    _ZDOT_MODULES_LOADED[$module]=1

    # Clear the module directory and name after loading
    unset _ZDOT_CURRENT_MODULE_DIR
    unset _ZDOT_CURRENT_MODULE_NAME
}

# List all loaded modules
# Usage: zdot_module_list
zdot_module_list() {
    zdot_info "Loaded modules:"
    for module in ${(k)_ZDOT_MODULES_LOADED}; do
        zdot_info "  $module"
    done
}
