#!/usr/bin/env zsh
# starship-prompt: Starship prompt
#
# Initialises starship as the shell prompt. Provides 'prompt-ready'.
# Only one prompt module should be loaded at a time.
#
# Load in your .zshrc:
#   zdot_load_module starship-prompt
#
# Configuration:
#   Config file defaults to starship's own default ($XDG_CONFIG_HOME/starship.toml).
#   Override via zstyle, or hook into the starship-prompt-configure group:
#     zstyle ':zdot:starship-prompt' config '/path/to/starship.toml'

_starship_prompt_init() {
    command -v starship &>/dev/null || {
        zdot_verbose "starship-prompt: starship not found, skipping"
        return 0
    }

    local _config
    if zstyle -s ':zdot:starship-prompt' config _config && [[ -n "$_config" ]]; then
        export STARSHIP_CONFIG="$_config"
    fi

    eval "$(starship init zsh)"
}

zdot_register_hook _starship_prompt_init interactive \
    --name starship-prompt \
    --requires xdg-configured \
    --requires-group starship-prompt-configure \
    --requires-tool starship \
    --provides prompt-ready \
    --optional
