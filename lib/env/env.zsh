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
    export DEFAULT_USER=geohar

    # Development directories
    export DEVDIR="${HOME}/Development"
    export DEPLOYDIR="${HOME}/Deployments"
    if is-macos; then
        export EXTDEVDIR="${DEVDIR}/ext"
    else
        export EXTDEVDIR="${HOME}/ext"
    fi

    # Terminal color configuration
    if [[ ${TERM} == "xterm-256color" ]]; then
        export COLORTERM=256
    fi

    # Eza
    if command -v eza &> /dev/null; then
        export EZA_ICONS_AUTO=1
    fi

    # Basic memory
    export BASIC_MEMORY_HOME="${HOME}/basic-memory"
    export BASIC_MEMORY_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/basic-memory"

    # opencode path
    # export OPENCODE_BIN_PATH=/Users/geohar/Development/ext/opencode/packages/opencode/dist/opencode-darwin-arm64/bin/opencode
    # export OPENCODE_SERVER_URL=http://localhost:4097
}

# Register hook - requires XDG paths for tool configurations
zdot_hook_register _env_init interactive noninteractive \
    --requires xdg-configured \
    --provides env-configured
