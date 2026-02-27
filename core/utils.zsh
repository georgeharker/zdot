#!/usr/bin/env zsh
# core/utils: Utility functions, platform detection, and host helpers
# ============================================================================
# Utility Functions
# ============================================================================

# Check if source file is newer than destination or destination is missing.
# Resolves symlinks on both paths via :A (zsh builtin, faster than realpath)
# so that mtime comparisons use the real file mtimes, not the symlink mtimes.
# This is important because zsh's -nt uses lstat() and does not follow symlinks.
# Usage: if zdot_is_newer_or_missing <source> <dest>; then ...; fi
zdot_is_newer_or_missing() {
    local src="$1"
    local dst="$2"
    if [[ ! -f "$dst" ]]; then
        return 0
    fi
    if [[ -f "$src" && "$src:A" -nt "$dst:A" ]]; then
        return 0
    fi
    return 1
}

# Source a file relative to the calling module
# Usage: zdot_module_source <relative-path>
zdot_module_source() {
    local rel_path="$1"
    zdot_module_dir
    local module_dir="$REPLY"

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
        if zdot_is_newer_or_missing "$source_file" "$compiled_path"; then
            zdot_cache_compile_file "$source_file"
        fi
    fi

    # Always source the .zsh file - zsh will automatically use .zwc if it exists
    source "$source_file"
}

# ============================================================================
# Platform Detection
# ============================================================================

# Check if running on macOS.
# Available from bootstrap (before xdg loads), unlike is-macos() in xdg.zsh.
# Usage: if zdot_is_macos; then ...; fi
zdot_is_macos() {
    [[ "$OSTYPE" == darwin* ]]
}

# Check if running on Debian (or a Debian-derived distro).
# Available from bootstrap (before xdg loads), unlike is-debian() in xdg.zsh.
# Usage: if zdot_is_debian; then ...; fi
zdot_is_debian() {
    [[ "$OSTYPE" == linux* && -f /etc/debian_version ]]
}

# ============================================================================
# Host Detection
# ============================================================================

typeset -g SHORT_HOST

zdot_init_short_host() {
    [[ -n "$SHORT_HOST" ]] && return 0

    if [[ "$OSTYPE" = darwin* ]]; then
        SHORT_HOST=$(scutil --get LocalHostName 2>/dev/null) || SHORT_HOST="${HOST/.*/}"
    else
        SHORT_HOST="${HOST/.*/}"
    fi
}

# Must run eagerly at source time (not in zsh-defer) so scutil doesn't block
# a deferred callback.
zdot_init_short_host

# Debug: show all registered hooks and loaded modules
# Usage: zdot_debug_info
zdot_debug_info() {
    zdot_report "=== ZSH Info ==="
    zdot_info ""
    zdot_module_list
    zdot_info ""
    zdot_hooks_list
    zdot_info ""
    zdot_show_plan
    zdot_info ""
    zdot_report "Completion commands to generate: ${#_ZDOT_COMPLETION_CMDS}"
    zdot_report "Live completion functions: ${#_ZDOT_COMPLETION_LIVE}"
}
