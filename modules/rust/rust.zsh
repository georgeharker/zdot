#!/usr/bin/env zsh
# rust: Rust toolchain and cargo environment
# Manages Rust installation, cargo environment, and completions

_rust_init() {
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    zdot_register_completion_file "rustup" "rustup completions zsh"
    zdot_register_completion_file "cargo" "rustup completions zsh cargo"
}

# --group completions-producers: _rust_init registers completions in its body,
# so completions finalization must wait for it (see modules/completions).
zdot_simple_hook rust --provides rust-ready --requires-group rust-configure \
    --group completions-producers
