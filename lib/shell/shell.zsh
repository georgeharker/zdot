#!/usr/bin/env zsh
# Shell configuration module
# History settings and shell options

_shell_init() {
    # Setup history directory
    if [[ ! -d ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history ]]; then
        mkdir -p ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history
        [[ -f ${HOME}/.zsh_history ]] && mv ${HOME}/.zsh_history ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history/history
    fi

    # History configuration
    HISTFILE=${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history/history
    HISTORY_BASE=${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-directory-history/

    # Shell options
    setopt share_history
}

# Register hook - requires XDG paths for history directory
zdot_hook_register _shell_init interactive noninteractive \
    --requires xdg-configured \
    --provides shell-configured
