#!/usr/bin/env zsh
# Local RC module
# User-specific local modifications

_local_rc_init() {
    # Source local modifications if they exist
    # This allows per-machine customization without affecting the main config
    if [ -f ~/.zshrc_local ]; then
        source ~/.zshrc_local
    fi
}

# Register hook: runs late to allow local overrides of anything
# Optional dependency on secrets - runs after secrets if available, otherwise runs anyway
zdot_hook_register _local_rc_init interactive noninteractive \
    --requires secrets-loaded \
    --optional \
    --provides local-overrides-loaded
