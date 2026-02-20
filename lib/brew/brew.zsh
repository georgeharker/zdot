#!/usr/bin/env zsh
# brew: Homebrew package manager environment
# Initializes Homebrew PATH and environment variables on macOS

_brew_init() {
    # .zshrc only loads this module on macOS, but guard defensively
    zdot_is_macos || return 0

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

    zdot_verify_tools op fzf eza oh-my-posh gh tailscale
}

# Register hooks - requires xdg-configured, provides brew-ready and tool availability
zdot_hook_register _brew_init interactive noninteractive \
    --requires xdg-configured \
    --provides brew-ready \
    --provides-tool op \
    --provides-tool fzf \
    --provides-tool eza \
    --provides-tool oh-my-posh \
    --provides-tool gh \
    --provides-tool tailscale
