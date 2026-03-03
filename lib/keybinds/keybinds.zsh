#!/usr/bin/env zsh
# Key bindings module
# Centralizes all custom key bindings

_keybinds_init() {
    # Word navigation
    bindkey '^[C' forward-word
    bindkey '^[D' backward-word
    bindkey '^[[H' beginning-of-line
    bindkey '^[[F' end-of-line
}

# Register hook: requires plugins to be loaded and post-configured
# Keybinds only needed in interactive shells
zdot_simple_hook keybinds --no-requires --context interactive
