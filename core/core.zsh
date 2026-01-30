#!/usr/bin/env zsh
# core/core: Global state and bootstrap
# Defines core data structures and paths

# ============================================================================
# Path Discovery - NO XDG Dependencies
# ============================================================================

# Self-discover zsh-base location using the currently sourced file
# This file is at: .config/zsh/lib/zsh-base/core.zsh
_zdot_this_script_file="${${(%):-%x}:A}"
_zdot_base_dir="${_zdot_this_script_file:h}"     # .../zdot
typeset -g _ZDOT_LIB_DIR="${_zdot_base_dir:h}/lib"          # .../lib
unset _zdot_base_file _zdot_base_dir

# ============================================================================
# Lazy Path Evaluation - XDG-Dependent
# ============================================================================

# These paths depend on XDG_CONFIG_HOME which is set by the xdg module
# and may change later (e.g., by sudo module calling xdg_mutable_dirs)
# Compute them on-demand to always get the current value

# Get functions directory (respects current XDG_CONFIG_HOME)
_zdot_functions_dir() {
    echo "${XDG_CONFIG_HOME:-${HOME}/.config}/zsh/functions"
}

# Get completions directory (respects current XDG_CACHE_HOME)
# Generated completions are cache data, not configuration
_zdot_completions_dir() {
    echo "${XDG_CACHE_HOME:-${HOME}/.cache}/zsh/completions"
}

# ============================================================================
# Global State
# ============================================================================

typeset -gA _ZDOT_PHASES          # phase_name@context -> array of hook functions
typeset -gA _ZDOT_MODULES_LOADED  # module_name -> 1 (loaded status)
typeset -gA _ZDOT_HOOK_MODULES    # hook_function -> module_name (tracks which module registered each hook)
typeset -g _ZDOT_CURRENT_MODULE_DIR  # Set by zdot_module_load, used by modules
typeset -g _ZDOT_CURRENT_MODULE_NAME  # Set by zdot_module_load, module name being loaded

# Context detection state (computed once at runtime)
typeset -g _ZDOT_IS_INTERACTIVE   # Set to 1 if interactive shell, 0 otherwise
typeset -g _ZDOT_IS_LOGIN         # Set to 1 if login shell, 0 otherwise

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
