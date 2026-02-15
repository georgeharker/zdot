#!/usr/bin/env zsh
# bun: Bun toolchain and cargo environment
# Manages Bun installation and completions

_bun_init() {
    # Bun is installed via homebrew, just mark as ready
    return 0
}

# Register hooks
zdot_hook_register _bun_init interactive noninteractive \
    --requires xdg-configured \
    --provides bun-ready

# Register completions
zdot_completion_register_file "bub" "bun completions zsh > $(_zdot_completions_dir)/_bun"
