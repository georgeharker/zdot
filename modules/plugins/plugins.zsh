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
