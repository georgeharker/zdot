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
zdot_hook_register _uv_init interactive noninteractive \
    --requires secrets-loaded \
    --optional \
    --provides uv-configured

zdot_completion_register_file "uv" "uv generate-shell-completion zsh"
zdot_completion_register_file "uvx" "uvx --generate-shell-completion zsh"
