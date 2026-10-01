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
    # Availability is gated declaratively: --requires-optional-tool skips this
    # hook when starship isn't on PATH (after the tool provider ran).

    local _config
    if zstyle -s ':zdot:starship-prompt' config _config && [[ -n "$_config" ]]; then
        export STARSHIP_CONFIG="$_config"
    fi

    eval "$(starship init zsh)"
}

zdot_register_hook _starship_prompt_init interactive \
    --name starship-prompt \
    --deferred-prompt \
    --requires bootstrap-ready \
    --requires-group starship-prompt-configure \
    --requires-optional-tool starship \
    --provides prompt-ready
