#!/usr/bin/env zsh
# UV (Python package manager) module
# Astral's uv - fast Python package installer

_uv_init() {
    # Load uv environment if available
    if [ -f "$HOME/.local/bin/env" ]; then
        source "$HOME/.local/bin/env"
    fi

    # Generate completions if uv is installed
    # if command -v uv &> /dev/null; then
    #     eval "$(uv generate-shell-completion zsh)"
    #     eval "$(uvx --generate-shell-completion zsh)"
    # fi

    # Activate global Python virtualenv if available
    [ -f ~/.venv/bin/activate ] && source ~/.venv/bin/activate
}

# Register hook for after-secrets phase
zdot_hook_register after-secrets _uv_init interactive noninteractive

zdot_completion_register_file "uv" "uv generate-shell-completion zsh"
zdot_completion_register_file "uvx" "uvx --generate-shell-completion zsh"
