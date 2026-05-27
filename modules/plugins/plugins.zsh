#!/usr/bin/env zsh
# Plugins: zdot-plugins manager setup
# Uses zdot-plugins for plugin management (now in core/plugins.zsh)
#
# Bundle-specific modules (e.g. `omz`) live separately. Load those
# alongside `plugins` to opt in.
#
# Ships sensible defaults via hooks in the `plugins-configure` group. Each
# default applies only if the zstyle is unset, so you can override anywhere
# in .zshrc with a plain `zstyle ...` line — no ordering concerns. To layer
# more plugin-side configuration, register your own hook in the group:
#
#   _my_plugins_config() {
#       zstyle ':zdot:plugin-update' frequency 7200   # every 2h
#   }
#   zdot_register_hook _my_plugins_config interactive noninteractive \
#       --group plugins-configure
#
# Defaults shipped here:
#   :zdot:plugin-update mode -> prompt
#     (background scan + Y/n upgrade prompt; flip to 'reminder' for
#      print-only, or 'disabled' to opt out entirely)

# ============================================================================
# Background plugin-update reminders
# ============================================================================
# Engine lives in core/plugin-update.zsh (sourced by zdot.zsh; gets
# compiled with the rest of core). Bundle-aware: scans every git-backed
# plugin in _ZDOT_PLUGINS_PATH and _ZDOT_BUNDLE_REPOS (covers OMZ, pz,
# plain user/repo specs).

_zdot_plugins_configure_default() {
    zdot_zstyle_default ':zdot:plugin-update' mode prompt
}

zdot_register_hook _zdot_plugins_configure_default interactive noninteractive \
    --name plugins-configure-default \
    --group plugins-configure

zdot_register_hook _zdot_plugin_update_main interactive \
    --name plugin-update \
    --requires-group plugins-configure
