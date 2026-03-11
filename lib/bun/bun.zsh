#!/usr/bin/env zsh
# bun: Bun toolchain and cargo environment
# Manages Bun installation and completions

_bun_init() {
    export BUN_DNS_USE_IPV4=1
    # Bun is installed via homebrew, just mark as ready
    return 0
}

# Register hooks
zdot_simple_hook bun --provides bun-ready

# Register completions
zdot_register_completion_file "bun" "bun completions zsh > $(zdot_get_completions_dir)/_bun"
