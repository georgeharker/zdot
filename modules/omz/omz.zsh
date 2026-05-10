#!/usr/bin/env zsh
# omz: Oh-My-Zsh bundle declaration
#
# Declares omz:lib so OMZ appears in the clone manifest and update flow.
# Load alongside the `plugins` module when OMZ is your bundle:
#   zdot_load_module plugins
#   zdot_load_module omz
#
# Ships sensible defaults via hooks in the `omz-configure` group. Each
# default applies only if the zstyle is unset, so you can override anywhere
# in .zshrc with a plain `zstyle ...` line — no ordering concerns. To layer
# more OMZ-side configuration, register your own hook in the group:
#
#   _my_omz_config() {
#       zstyle ':omz:plugins:eza' dirs-first yes
#   }
#   zdot_register_hook _my_omz_config interactive noninteractive \
#       --group omz-configure
#
# Defaults shipped here:
#   :omz:update mode  -> prompt   (OMZ self-update prompts the user)
#
# The OMZ bundle handler in core/plugin-bundles/omz.zsh waits on the
# omz-configure group via --requires-group, so any zstyle set there lands
# before the bundle initialises.
#
# The bundle handler is independently gated by zstyle ':zdot:plugins' omz
# (default: yes); set to no to skip cloning OMZ even with this module loaded.

_omz_configure_update() {
    local _m
    zstyle -s ':omz:update' mode _m || zstyle ':omz:update' mode prompt
}

zdot_register_hook _omz_configure_update interactive noninteractive \
    --name omz-configure-update \
    --group omz-configure

zdot_use_plugin omz:lib
