#!/usr/bin/env zsh
# SSH connection and tmux auto-start handling
# Manages tmux behavior when connecting via SSH

_ssh_init() {
    # tmux configuration for SSH connections
    if [[ "${SSH_CONNECTION}" != "" ]]; then
        # Don't launch tmux inside screen/tmux
        if [[ "${TERM}" =~ "^screen-.*" || "${TERM}" =~ "^tmux-.*" || -f ~/.notmux ]]; then
            ZSH_TMUX_AUTOSTART="false"
            ZSH_TMUX_AUTOQUIT="false"
        else
            ZSH_TMUX_AUTOSTART="true"
            ZSH_TMUX_AUTOSTART_ONCE="true"
            ZSH_TMUX_AUTOCONNECT="true"
        fi
    fi
    ZSH_TMUX_UNICODE="true"
}

# Register initialization hook - no dependencies, sets tmux flags
zdot_simple_hook ssh --no-requires
