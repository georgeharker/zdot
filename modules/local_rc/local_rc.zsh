#!/usr/bin/env zsh
# Local RC module
# User-specific local modifications

_local_env_init() {
    # Source local modifications if they exist
    # This allows per-machine customization without affecting the main config
    if [ -f ~/.zshenv_local ]; then
        source ~/.zshenv_local
    fi
}

# Register hook: runs early to set per machine styles.
# Member of the bootstrap group, so it runs (after xdg-configured)
# before the bootstrap-ready phase is provided. See modules/bootstrap.
# Requires xdg-configured explicitly (NOT the bootstrap-ready default — this
# hook is a member of the group bootstrap-ready waits on, so depending on it
# would be circular).
zdot_simple_hook local_env --optional \
    --requires xdg-configured \
    --group bootstrap \
    --provides local-env-loaded

_local_rc_init() {
    # Source local modifications if they exist
    # This allows per-machine customization without affecting the main config
    if [ -f ~/.zshrc_local ]; then
        source ~/.zshrc_local
    fi
}

# Register hook: runs late to allow local overrides of anything
# Optional dependency on secrets - runs after secrets if available, otherwise runs anyway
zdot_simple_hook local_rc --requires secrets-loaded --optional --provides local-overrides-loaded
