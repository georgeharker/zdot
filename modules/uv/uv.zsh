#!/usr/bin/env zsh
# UV (Python package manager) module
# Astral's uv - fast Python package installer

_uv_init() {
    # Load uv environment if available
    if [ -f "$HOME/.local/bin/env" ]; then
        source "$HOME/.local/bin/env"
    fi

    # Activate global Python virtualenv if available
    [ -f ~/.venv/bin/activate ] && source ~/.venv/bin/activate
}

# Register hook: runs after secrets if available, otherwise runs anyway
zdot_simple_hook uv --requires secrets-loaded --optional

zdot_register_completion_file "uv" "uv generate-shell-completion zsh"
zdot_register_completion_file "uvx" "uvx --generate-shell-completion zsh"
