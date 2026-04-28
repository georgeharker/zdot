#!/usr/bin/env zsh
# rust: Rust toolchain and cargo environment
# Manages Rust installation, cargo environment, and completions

_rust_init() {
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    zdot_register_completion_file "rustup" "rustup completions zsh"
    zdot_register_completion_file "cargo" "rustup completions zsh cargo"
}

zdot_simple_hook rust --provides rust-ready
