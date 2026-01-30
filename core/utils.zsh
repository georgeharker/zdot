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
        echo "zdot_module_source: relative path required" >&2
        return 1
    fi

    local source_file="${module_dir}/${rel_path}"

    if [[ ! -f "$source_file" ]]; then
        echo "zdot_module_source: file not found: $source_file" >&2
        return 1
    fi

    source "$source_file"
}

# Debug: show all registered hooks and loaded modules
# Usage: zdot_base_debug
zdot_base_debug() {
    echo "=== ZSH Base Debug Info ==="
    echo
    zdot_module_list
    echo
    zdot_phase_list
    echo
    echo "Completion commands to generate: ${#_ZDOT_COMPLETION_CMDS}"
    echo "Live completion functions: ${#_ZDOT_COMPLETION_LIVE}"
}
