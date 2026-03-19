#!/usr/bin/env zsh
# omp-prompt: oh-my-posh prompt
#
# Initialises oh-my-posh as the shell prompt. Provides 'prompt-ready'.
# Only one prompt module should be loaded at a time.
#
# Load in your .zshrc:
#   zdot_load_module omp-prompt
#
# Configuration:
#   Theme file defaults to $XDG_CONFIG_HOME/oh-my-posh/theme.toml.
#   Override via zstyle, or hook into the omp-prompt-configure group:
#     zstyle ':zdot:omp-prompt' theme '/path/to/theme.toml'

_omp_prompt_init() {
    command -v oh-my-posh &>/dev/null || {
        zdot_verbose "omp-prompt: oh-my-posh not found, skipping"
        return 0
    }

    local _theme
    zstyle -s ':zdot:omp-prompt' theme _theme \
        || _theme="${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-posh/theme.toml"

    eval "$(oh-my-posh init zsh --config "$_theme")"
}

zdot_register_hook _omp_prompt_init interactive \
    --name omp-prompt \
    --requires xdg-configured \
    --requires-group omp-prompt-configure \
    --requires-tool oh-my-posh \
    --provides prompt-ready \
    --optional
