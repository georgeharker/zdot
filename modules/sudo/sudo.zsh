#!/usr/bin/env zsh
# Sudo user handling
# Configures overrides when running as sudo

_sudo_init() {
    # Configure overrides for use in sudo context
    if [[ ${SUDO_USER} != "" ]]; then
        REAL_HOME="${HOME:h}/${USER}"
        ZSH_TMUX_AUTOSTART="false"  # shuck: ignore=C001
        ZSH_TMUX_AUTOQUIT="false"  # shuck: ignore=C001
        export ZSH_COMPDUMP="${REAL_HOME}/.zcompdump-${SHORT_HOST}-${ZSH_VERSION}"
        export ZSH_DISABLE_COMPFIX=true
        xdg_mutable_dirs "${REAL_HOME}"
    fi
}

# Register hook - requires XDG functions for directory reconfiguration
zdot_simple_hook sudo
