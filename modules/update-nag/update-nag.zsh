#!/usr/bin/env zsh
# Update nagging
# Reminder updates for installers
#
# Configuration:
#   zstyle ':zdot:update-nag' plugin <user/repo>
#     Plugin spec passed to zdot_use_plugin / zdot_load_plugin.
#     Default: madisonrickert/zsh-pkg-update-nag.
#
#   zstyle ':zdot:update-nag' mode <prompt|reminder>
#     Session-start presentation. `prompt` (plugin default) offers the inline
#     [Y/n/s] upgrade prompt; `reminder` just lists what's outdated and prints a
#     one-line instruction to upgrade on demand, without reading the terminal.
#     Unset leaves the plugin's own default (and any config.zsh setting) intact.
#
#   zstyle ':zdot:update-nag' reminder-command <command>
#     Command suggested by `reminder` mode (default: "zsh-pkg-update-nag --now").
#     Point it at whatever you use to run the upgrade interactively.
#
# The `plugin` style is read at module-source time, so it must be set before the
# module file is sourced. `mode` / `reminder-command` are read in the configure
# phase, so they may be set any time before that — directly in .zshrc, or from a
# before-module callback:
#
#   zdot_before_module update-nag --fn _my_update_nag_config
#   _my_update_nag_config() {
#       zstyle ':zdot:update-nag' plugin 'fork/zsh-pkg-update-nag'
#       zstyle ':zdot:update-nag' mode reminder
#   }
#
# Other configuration (e.g. ZSH_PKG_UPDATE_NAG_* env vars) can be set from
# hooks attached to the update-nag-configure group.

zdot_zstyle_get ':zdot:update-nag' plugin _update_nag_plugin_spec 'madisonrickert/zsh-pkg-update-nag'

zdot_use_plugin "${_update_nag_plugin_spec}"  # shuck: ignore=C006  # assigned indirectly by zdot_zstyle_get

_update_nag_configure() {
    export ZSH_PKG_UPDATE_NAG_BACKGROUND=1
    # Plugin config auto-loads from ${XDG_CONFIG_HOME}/zsh-pkg-update-nag/config.zsh

    # Bridge zstyle → the plugin's config params. Only export when the style is
    # actually set, so an unset style falls through to the plugin's own default
    # (or the user's config.zsh). Distinct var names avoid colliding with
    # zdot_zstyle_get's internal locals (_mode, ctx, style, var).
    local _un_mode _un_reminder_cmd
    if zdot_zstyle_get ':zdot:update-nag' mode _un_mode; then
        export zsh_pkg_update_nag_mode="${_un_mode}"
    fi
    if zdot_zstyle_get ':zdot:update-nag' reminder-command _un_reminder_cmd; then
        export zsh_pkg_update_nag_reminder_command="${_un_reminder_cmd}"
    fi
}

_update_nag_load() {
    zdot_load_plugin "${_update_nag_plugin_spec}"
}

zdot_define_module update-nag \
    --configure _update_nag_configure \
    --load _update_nag_load \
    --context interactive \
    --auto-configure-group
