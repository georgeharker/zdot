#!/usr/bin/env zsh
# Dotfiler module
# Dotfiler repository update checker and custom scripts

_dotfiler_init() {
    zstyle ':dotfiler:update' mode prompt

    # Compile dotfiler scripts to .zwc for faster sourcing
    if zdot_cache_is_enabled; then
        local _dotfiler_scripts="$HOME/.dotfiles/.nounpack/dotfiler"
        zdot_cache_compile_functions "$_dotfiler_scripts" '*.zsh'
        unset _dotfiler_scripts
    fi

    # Source dotfiles update checker (requires GH_TOKEN from 1Password)
    [[ -f "$HOME/.dotfiles/.nounpack/dotfiler/check_update.zsh" ]] && \
        source "$HOME/.dotfiles/.nounpack/dotfiler/check_update.zsh"

    # Source dotfiles completions
    [[ -f "$HOME/.dotfiles/.nounpack/dotfiler/completions.zsh" ]] && \
        source "$HOME/.dotfiles/.nounpack/dotfiler/completions.zsh"
}

# Register hook: requires secrets for GH_TOKEN
# Only needed in interactive shells
zdot_simple_hook dotfiler --requires secrets-loaded --provides dotfiler-ready --context interactive
