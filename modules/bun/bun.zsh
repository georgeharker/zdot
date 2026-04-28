#!/usr/bin/env zsh
# bun: Bun toolchain and cargo environment
# Manages Bun installation and completions

_bun_init() {
    export BUN_DNS_USE_IPV4=1
    zdot_register_completion_file "bun" "bun completions zsh"
}

zdot_simple_hook bun --provides bun-ready
