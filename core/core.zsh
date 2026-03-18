#!/usr/bin/env zsh
# core/core: Global state and bootstrap
# Defines core data structures and paths

# ============================================================================
# Path Discovery - NO XDG Dependencies
# ============================================================================

# Self-discover zsh-base location using the currently sourced file
# This file is at: .config/zsh/zdot/core/core.zsh
# NOTE: Using :a (absolute path without resolving symlinks) instead of :A
# (which would follow symlinks to the real path). This is intentional:
# ZDOT_DIR must point at the linktree path (e.g. ~/.config/zdot)
# rather than the backing store (e.g. ~/.dotfiles/.config/zdot), so that
# any paths derived from it remain consistent with how the user addresses
# the directory. Mtime comparisons that use ZDOT_DIR pass through
# zdot_is_newer_or_missing, which applies :A at comparison time.
#
# ZDOT_REPO always points at the real backing repo (symlinks resolved via :A).
# Use ZDOT_REPO wherever git operations need the actual worktree, not the
# linktree — e.g. update scripts calling git rev-parse.
_zdot_this_script_file="${${(%):-%x}:a}"
_zdot_base_dir="${_zdot_this_script_file:h:h}"     # .../zdot (go up twice from core/)
typeset -g ZDOT_DIR="${_zdot_base_dir}"              # Export as global (linktree path)
typeset -g _ZDOT_MODULE_DIR="${_zdot_base_dir}/modules"      # .../zdot/modules
_zdot_this_real_script_file="${${(%):-%x}:A}"
_zdot_repo_dir="${_zdot_this_real_script_file:h:h}" # .../zdot real path (symlinks resolved)
typeset -g ZDOT_REPO="${_zdot_repo_dir}"             # Export as global (real repo path)
unset _zdot_this_script_file _zdot_base_dir _zdot_this_real_script_file _zdot_repo_dir

# ============================================================================
# Lazy Path Evaluation - XDG-Dependent
# ============================================================================

# These paths depend on XDG_CONFIG_HOME which is set by the xdg module
# and may change later (e.g., by sudo module calling xdg_mutable_dirs)
# Compute them on-demand to always get the current value

# Get functions directory (respects current XDG_CONFIG_HOME)
_zdot_functions_dir() {
    REPLY="${XDG_CONFIG_HOME:-${HOME}/.config}/zsh/functions"
}

# Get completions directory (respects current XDG_CACHE_HOME)
# Generated completions are cache data, not configuration
_zdot_completions_dir() {
    REPLY="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/completions"
}

# Public stdout wrapper — for use in lib/ callsites where subshells are acceptable.
# Usage: local dir="$(zdot_get_completions_dir)"
zdot_get_completions_dir() {
    _zdot_completions_dir
    print -- "$REPLY"
}

# ============================================================================
# Global State
# ============================================================================

typeset -gA _ZDOT_PHASES          # phase_name@context -> array of hook functions
typeset -gA _ZDOT_MODULES_LOADED    # module_name -> 1 (loaded status)
typeset -gA _ZDOT_HOOK_MODULES      # hook_function -> module_name (tracks which module registered each hook)
typeset -g _ZDOT_CURRENT_MODULE_DIR   # Set by zdot_load_module, used by modules
typeset -g _ZDOT_CURRENT_MODULE_NAME  # Set by zdot_load_module, module name being loaded

# Ordered list of directories to search when resolving a module by name.
# Populated lazily by _zdot_build_module_search_path from
# zstyle ':zdot:modules' search-path (array); _ZDOT_MODULE_DIR is always appended last.
# Example zstyle:
#   zstyle ':zdot:modules' search-path \
#       "${XDG_CONFIG_HOME}/zsh/modules" \
#       "${HOME}/.dotfiles/zsh-extra"
typeset -ga _ZDOT_MODULE_SEARCH_PATH

# module_name -> absolute directory it was loaded from (the module's own dir, not the search root)
# e.g. _ZDOT_MODULE_SOURCE_DIR["xdg"]="/Users/user/.config/zdot/modules/xdg"
typeset -gA _ZDOT_MODULE_SOURCE_DIR

# Context detection state (computed once at runtime)
typeset -g _ZDOT_IS_INTERACTIVE   # Set to 1 if interactive shell, 0 otherwise
typeset -g _ZDOT_IS_LOGIN         # Set to 1 if login shell, 0 otherwise

# User variant state (resolved once at plan-build time from env/zstyle/function)
typeset -g _ZDOT_VARIANT=""            # Active variant string (empty = default)
typeset -g _ZDOT_VARIANT_DETECTED=0   # 1 once zdot_resolve_variant has run
typeset -g _ZDOT_VARIANT_INDEX_BUILT=0 # 1 once _zdot_build_variant_provider_index has run

# Phase execution tracking
typeset -ga _ZDOT_PHASE_EXECUTION_ORDER  # Array of phase names in the order they were executed

# Completion registration arrays
typeset -ga _ZDOT_COMPLETION_CMDS         # Ordered list of commands to generate completions for
typeset -gA _ZDOT_COMPLETION_GEN          # cmd -> generation command
typeset -gA _ZDOT_COMPLETION_DEST         # cmd -> destination directory
typeset -ga _ZDOT_COMPLETION_LIVE         # Functions to run live during init

# ============================================================================
# Context Detection
# ============================================================================

# Detect and cache shell context at startup
if [[ -o interactive ]]; then
    _ZDOT_IS_INTERACTIVE=1
else
    _ZDOT_IS_INTERACTIVE=0
fi

if [[ -o login ]]; then
    _ZDOT_IS_LOGIN=1
else
    _ZDOT_IS_LOGIN=0
fi
