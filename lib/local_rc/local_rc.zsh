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

# Register hook for after-secrets phase (runs late to allow overriding anything)
zdot_hook_register after-secrets _local_rc_init interactive noninteractive
