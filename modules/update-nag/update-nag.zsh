#!/usr/bin/env zsh
# Update nagging
# Reminder updates for installers

zdot_use_plugin madisonrickert/zsh-pkg-update-nag

_update_nag_init() {
    export ZSH_PKG_UPDATE_NAG_BACKGROUND=1
    # Config auto-loads from ${XDG_CONFIG_HOME}/zsh-pkg-update-nag/config.zsh
    zdot_load_plugin madisonrickert/zsh-pkg-update-nag
}

# Register hook - requires XDG paths for tool configurations
zdot_simple_hook update_nag
