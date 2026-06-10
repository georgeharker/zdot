#!/usr/bin/env zsh
# Update nagging
# Reminder updates for installers
#
# Configuration:
#   zstyle ':zdot:update-nag' plugin <user/repo>
#     Plugin spec passed to zdot_use_plugin / zdot_load_plugin.
#     Default: madisonrickert/zsh-pkg-update-nag.
#
# Because zdot_use_plugin runs at module-source time, the zstyle must be set
# before the module file is sourced. Either set it directly in .zshrc before
# `zdot_load_module update-nag`, or register a before-module callback:
#
#   zdot_before_module update-nag --fn _my_update_nag_config
#   _my_update_nag_config() {
#       zstyle ':zdot:update-nag' plugin 'fork/zsh-pkg-update-nag'
#   }
#
# Other configuration (e.g. ZSH_PKG_UPDATE_NAG_* env vars) can be set from
# hooks attached to the update-nag-configure group.

zdot_zstyle_get ':zdot:update-nag' plugin _update_nag_plugin_spec 'georgeharker/zsh-pkg-update-nag'

zdot_use_plugin "${_update_nag_plugin_spec}"  # shuck: ignore=C006  # assigned indirectly by zdot_zstyle_get

_update_nag_configure() {
    export ZSH_PKG_UPDATE_NAG_BACKGROUND=1
    # Plugin config auto-loads from ${XDG_CONFIG_HOME}/zsh-pkg-update-nag/config.zsh
}

_update_nag_load() {
    zdot_load_plugin "${_update_nag_plugin_spec}"
}

zdot_define_module update-nag \
    --configure _update_nag_configure \
    --load _update_nag_load \
    --context interactive \
    --auto-configure-group
