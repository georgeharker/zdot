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
# Sets _ZDOT_CURRENT_CONTEXT to a space-separated pair of tokens:
#   - one of: interactive | noninteractive
#   - one of: login | nonlogin
# e.g. "interactive nonlogin"
#
# The shell's context is determined once at plan-build time and is stable
# for the lifetime of the shell.  Storing it in a global allows runtime
# consumers (deferred dispatch, requirements checks) to filter context-
# restricted requires without re-deriving the context each time.
#
# Usage: zdot_build_context   (call before zdot_build_execution_plan)
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
}
