#!/usr/bin/env zsh
# zsh-base/utils: Utility functions
# Provides debugging and helper functions

# ============================================================================
# Context Helper Functions
# ============================================================================

# Check if current shell is interactive
# Returns 0 (true) if interactive, 1 (false) otherwise
# Usage: if zdot_interactive; then ...; fi
zdot_interactive() {
    [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]]
}

# Check if current shell is a login shell
# Returns 0 (true) if login shell, 1 (false) otherwise
# Usage: if zdot_login; then ...; fi
zdot_login() {
    [[ $_ZDOT_IS_LOGIN -eq 1 ]]
}

# ============================================================================
# Utility Functions
# ============================================================================

# Source a file relative to the calling module
# Usage: zdot_module_source <relative-path>
zdot_module_source() {
    local rel_path="$1"
    local module_dir=$(zdot_module_dir)

    if [[ -z "$rel_path" ]]; then
        zdot_error "zdot_module_source: relative path required"
        return 1
    fi

    local source_file="${module_dir}/${rel_path}"

    if [[ ! -f "$source_file" ]]; then
        zdot_error "zdot_module_source: file not found: $source_file"
        return 1
    fi

    # If caching is enabled, compile if needed
    if zdot_cache_is_enabled; then
        local compiled_path="${source_file}.zwc"
        if [[ ! -f "$compiled_path" || "$source_file" -nt "$compiled_path" ]]; then
            zdot_cache_compile_file "$source_file"
        fi
    fi

    # Always source the .zsh file - zsh will automatically use .zwc if it exists
    source "$source_file"
}

# Debug: show all registered hooks and loaded modules
# Usage: zdot_base_debug
zdot_base_debug() {
    zdot_info "=== ZSH Base Debug Info ==="
    zdot_info ""
    zdot_module_list
    zdot_info ""
    zdot_hooks_list
    zdot_info ""
    zdot_info "Completion commands to generate: ${#_ZDOT_COMPLETION_CMDS}"
    zdot_info "Live completion functions: ${#_ZDOT_COMPLETION_LIVE}"
}
