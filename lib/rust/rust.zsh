#!/usr/bin/env zsh
# rust: Rust toolchain and cargo environment
# Manages Rust installation, cargo environment, and completions

_rust_init() {
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
}

# Register hooks
zdot_hook_register _rust_init interactive noninteractive \
    --requires xdg-configured \
    --provides rust-ready

# Register completions
zdot_completion_register_file "rustup" "rustup completions zsh > $(_zdot_completions_dir)/_rustup"
zdot_completion_register_file "cargo" "rustup completions zsh cargo > $(_zdot_completions_dir)/_cargo"
