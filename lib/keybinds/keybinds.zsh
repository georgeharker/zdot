#!/usr/bin/env zsh
# Key bindings module
# Centralizes all custom key bindings

_keybinds_init() {
    # Word navigation
    bindkey '\eC' forward-word
    bindkey '\eD' backward-word
    # mac fn-key navigation
    bindkey '\e[H' beginning-of-line
    bindkey '\e[F' end-of-line
    bindkey '\e[5~' history-search-backward
    bindkey '\e[6~' history-search-forward
}

# Register hook: requires plugins to be loaded and post-configured
# Keybinds only needed in interactive shells
zdot_simple_hook keybinds --no-requires --context interactive
