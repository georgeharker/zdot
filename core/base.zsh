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
