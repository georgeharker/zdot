#!/usr/bin/env zsh
# Shell configuration module
# History settings and shell options

zdot_use_plugin jimhester/per-directory-history

_shell_init() {
    zdot_load_plugin jimhester/per-directory-history

    # Setup history directory
    if [[ ! -d ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history ]]; then
        mkdir -p ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history
        [[ -f ${HOME}/.zsh_history ]] && mv ${HOME}/.zsh_history ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history/history
    fi

    # History configuration
    HISTFILE=${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history/history
    HISTORY_BASE=${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-directory-history/

    # Shell options
    setopt INC_APPEND_HISTORY
    setopt SHARE_HISTORY
}

# Register hook - requires XDG paths for history directory
zdot_simple_hook shell
