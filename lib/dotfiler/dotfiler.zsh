#!/usr/bin/env zsh
# Dotfiler module
# Dotfiler repository update checker and custom scripts

_dotfiler_init() {
    zstyle ':dotfiles:update' mode prompt

    # Source dotfiles update checker (requires GH_TOKEN from 1Password)
    [[ -f "$HOME/.dotfiles/.nounpack/scripts/check_update.sh" ]] && \
        source "$HOME/.dotfiles/.nounpack/scripts/check_update.sh"

    # Source dotfiles completions
    [[ -f "$HOME/.dotfiles/.nounpack/scripts/completions.zsh" ]] && \
        source "$HOME/.dotfiles/.nounpack/scripts/completions.zsh"
}

# Register hook for after-secrets phase (needs GH_TOKEN from 1Password)
zdot_hook_register after-secrets _dotfiler_init interactive
