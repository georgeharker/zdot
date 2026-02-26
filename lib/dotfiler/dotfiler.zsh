#!/usr/bin/env zsh
# Dotfiler module
# Dotfiler repository update checker and custom scripts

_dotfiler_init() {
    zstyle ':dotfiler:update' mode prompt

    # Compile dotfiler scripts to .zwc for faster sourcing
    if zdot_cache_is_enabled; then
        local _dotfiler_script
        for _dotfiler_script in \
            "$HOME/.dotfiles/.nounpack/scripts/helpers.sh" \
            "$HOME/.dotfiles/.nounpack/scripts/logging.sh" \
            "$HOME/.dotfiles/.nounpack/scripts/check_update.sh" \
            "$HOME/.dotfiles/.nounpack/scripts/completions.zsh"
        do
            [[ -f "$_dotfiler_script" ]] && zdot_cache_compile_file "$_dotfiler_script"
        done
        unset _dotfiler_script
    fi

    # Source dotfiles update checker (requires GH_TOKEN from 1Password)
    [[ -f "$HOME/.dotfiles/.nounpack/scripts/check_update.sh" ]] && \
        source "$HOME/.dotfiles/.nounpack/scripts/check_update.sh"

    # Source dotfiles completions
    [[ -f "$HOME/.dotfiles/.nounpack/scripts/completions.zsh" ]] && \
        source "$HOME/.dotfiles/.nounpack/scripts/completions.zsh"
}

# Register hook: requires secrets for GH_TOKEN
# Only needed in interactive shells
zdot_simple_hook dotfiler --requires secrets-loaded --provides dotfiler-ready --context interactive
