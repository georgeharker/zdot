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

# --group completions-producers: uv registers completions at module-source time
# (below), but the gen commands need `uv`/`uvx` on PATH — which _uv_init sources.
# Joining the group makes completions finalization wait for that.
zdot_simple_hook uv \
    --requires-group uv-configure \
    --provides-tool uv \
    --group completions-producers

zdot_register_completion_file "uv" "uv generate-shell-completion zsh"
zdot_register_completion_file "uvx" "uvx --generate-shell-completion zsh"
