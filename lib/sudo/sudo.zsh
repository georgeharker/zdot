#!/usr/bin/env zsh
# Sudo user handling
# Configures overrides when running as sudo

_sudo_init() {
    # Configure overrides for use in sudo context
    if [[ ${SUDO_USER} != "" ]]; then
        REAL_HOME="${HOME:h}/${USER}"
        ZSH_TMUX_AUTOSTART="false"
        ZSH_TMUX_AUTOQUIT="false"
        export ZSH_COMPDUMP="${REAL_HOME}/.zcompdump-${SHORT_HOST}-${ZSH_VERSION}"
        export ZSH_DISABLE_COMPFIX=true
        xdg_mutable_dirs "${REAL_HOME}"
    fi
}

# Register initialization hook for system phase (runs after ssh module in system phase)
zdot_hook_register system _sudo_init
