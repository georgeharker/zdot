#!/usr/bin/env zsh
# zsh-base/base: Base utility functions
# Provides helper functions

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

# Check if stdout is attached to a TTY (controlling terminal present).
# Distinct from zdot_interactive: 'zsh -i -c ...' is interactive but has no PTY.
# Use this when a feature requires actual terminal I/O (e.g. ZLE keybindings).
# Returns 0 (true) if a TTY is present, 1 (false) otherwise
# Usage: if zdot_has_tty; then ...; fi
zdot_has_tty() {
    [[ -t 1 ]]
}

# Compose and store the definitive current shell context.
# Sets _ZDOT_CURRENT_CONTEXT to a space-separated sequence of tokens:
#   - one of: interactive | noninteractive
#   - one of: login | nonlogin
#   - optionally: variant:<name>  (only when _ZDOT_VARIANT is non-empty)
# e.g. "interactive nonlogin" or "interactive nonlogin variant:work"
#
# The shell's context is determined once at plan-build time and is stable
# for the lifetime of the shell.  Storing it in a global allows runtime
# consumers (deferred dispatch, requirements checks) to filter context-
# restricted requires without re-deriving the context each time.
#
# Also calls zdot_resolve_variant to populate _ZDOT_VARIANT before the
# execution plan is built.
#
# Usage: zdot_build_context   (call before zdot_build_execution_plan)

# Resolve and store the active user variant.
# Called once from zdot_build_context (before plan build).
# Priority: $ZDOT_VARIANT env > zstyle ':zdot:variant' name > zdot_detect_variant()
zdot_resolve_variant() {
    if [[ -n "${ZDOT_VARIANT:-}" ]]; then
        _ZDOT_VARIANT="$ZDOT_VARIANT"
    elif zstyle -s ':zdot:variant' name _ZDOT_VARIANT; then
        : # zstyle set it
    elif (( ${+functions[zdot_detect_variant]} )); then
        REPLY=""
        zdot_detect_variant
        _ZDOT_VARIANT="${REPLY:-}"
    else
        _ZDOT_VARIANT=""
    fi
    _ZDOT_VARIANT_DETECTED=1
}

# Return the active variant string (may be empty for the default variant).
# Usage: zdot_variant
zdot_variant() { print -r -- "$_ZDOT_VARIANT" }

# Return 0 if the active variant matches <name>, 1 otherwise.
# Usage: if zdot_is_variant work; then ...; fi
zdot_is_variant() { [[ "$_ZDOT_VARIANT" == "$1" ]] }

zdot_build_context() {
    if [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]]; then
        typeset -g _ZDOT_CURRENT_CONTEXT="interactive"
    else
        typeset -g _ZDOT_CURRENT_CONTEXT="noninteractive"
    fi
    if [[ $_ZDOT_IS_LOGIN -eq 1 ]]; then
        _ZDOT_CURRENT_CONTEXT+=" login"
    else
        _ZDOT_CURRENT_CONTEXT+=" nonlogin"
    fi

    zdot_resolve_variant

    # Append a variant: token only when a non-empty variant is active.
    # This keeps _ZDOT_CURRENT_CONTEXT backward-compatible for consumers
    # that only inspect interactive/login tokens.
    if [[ -n "$_ZDOT_VARIANT" ]]; then
        _ZDOT_CURRENT_CONTEXT+=" variant:$_ZDOT_VARIANT"
    fi
}
