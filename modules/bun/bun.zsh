#!/usr/bin/env zsh
# bun: Bun toolchain and cargo environment
# Manages Bun installation and completions

_bun_init() {
    export BUN_DNS_USE_IPV4=1
    zdot_register_completion_file "bun" "bun completions zsh"
}

# --group completions-producers: _bun_init registers completions in its body,
# so completions finalization must wait for it (see modules/completions).
zdot_simple_hook bun --provides bun-ready --requires-group bun-configure \
    --group completions-producers
