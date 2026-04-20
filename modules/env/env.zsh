#!/usr/bin/env zsh
# Environment variables module
# Centralized environment variable configuration

_env_init() {
    # Core environment
    export MANPATH="/usr/local/man:$MANPATH"
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export EDITOR='nvim'
    export PAGER='less -F -X'
    export MANPAGER="sh -c 'col -bx | bat --theme=default -l man -p'"
    export TMPDIR='/tmp'

    # Editor alias (matches EDITOR setting)
    alias vim=nvim

    # Path configuration
    export PATH="${HOME}/bin:${PATH}:${XDG_BIN_HOME}"

    # Tool configuration
    export RIPGREP_CONFIG_PATH="${XDG_CONFIG_HOME:-${HOME}/.config}/ripgrep/ripgrep.conf"
    export ZOXIDE_CMD_OVERRIDE=cz
    export _ZO_DATA_DIR=${XDG_DATA_HOME}
    export BAT_THEME="tokyonight_night"

    # Terminal color configuration
    if [[ ${TERM} == "xterm-256color" ]]; then
        export COLORTERM=256
    fi

    # Eza
    if command -v eza &> /dev/null; then
        export EZA_ICONS_AUTO=1
    fi
}

# Register hook - requires XDG paths for tool configurations
zdot_simple_hook env
