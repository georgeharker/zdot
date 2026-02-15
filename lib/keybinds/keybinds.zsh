#!/usr/bin/env zsh
# Key bindings module
# Centralizes all custom key bindings

_keybinds_init() {
    # Word navigation
    bindkey '[C' forward-word
    bindkey '[D' backward-word
}

# Register hook: requires plugins to be loaded and post-configured
# Keybinds only needed in interactive shells
zdot_hook_register _keybinds_init interactive \
    --requires plugins-post-configured \
    --provides keybinds-configured
