#!/usr/bin/env zsh
# Key bindings module
# Centralizes all custom key bindings

_keybinds_init() {
    # Word navigation
    bindkey '[C' forward-word
    bindkey '[D' backward-word
}

# Register hook for post-plugin phase (after plugins and functions are loaded)
# Keybinds only needed in interactive shells
zdot_hook_register post-plugin _keybinds_init interactive
