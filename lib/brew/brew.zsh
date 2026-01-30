#!/usr/bin/env zsh
# brew: Homebrew package manager environment
# Initializes Homebrew PATH and environment variables on macOS

_brew_init() {
    # Only run on macOS
    [[ `uname` != "Darwin" ]] && return 0
    
    # Skip if already initialized
    [[ -n "$HOMEBREW_PREFIX" ]] && return 0
    
    # Homebrew configuration
    export HOMEBREW_AUTO_UPDATE_SECS=3600
    export HOMEBREW_BAT=1
    export HOMEBREW_NO_ENV_HINTS=1
    
    # Initialize Homebrew environment
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

# Register hooks - runs in bootstrap phase for all shell types
zdot_hook_register bootstrap _brew_init interactive noninteractive
