#!/usr/bin/env zsh
# Plugins: zdot-plugins manager setup
# Uses zdot-plugins for plugin management (now in core/plugins.zsh)

# ============================================================================
# Plugin Configuration (zstyles for OMZ plugins)
# ============================================================================

_omz_configure_update() {
    zstyle ':omz:update' mode prompt
}

zdot_register_hook _omz_configure_update interactive noninteractive \
    --name omz-configure-update \
    --group omz-configure

zdot_use_plugin omz:lib

# ============================================================================
# Background plugin-update reminders (opt-in)
# ============================================================================
# Engine lives in core/plugin-update.zsh (sourced by zdot.zsh; gets
# compiled with the rest of core). Default mode is 'disabled', so the
# hook below short-circuits in _zdot_plugin_update_should_run for users
# who don't opt in.
#
# Activate from .zshrc:
#   zstyle ':zdot:plugin-update' mode      prompt   # disabled | reminder | prompt
#   zstyle ':zdot:plugin-update' frequency 14400    # seconds; default 4h

zdot_register_hook _zdot_plugin_update_main interactive \
    --name plugin-update
