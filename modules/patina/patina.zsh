#!/usr/bin/env zsh
# patina: zsh-patina syntax highlighter
#
# Activates zsh-patina, a Rust-based syntax highlighting daemon.
# Install via Homebrew (macOS), apt/deb (Debian/Ubuntu), or cargo.
#
# Load in your .zshrc:
#   zdot_load_module patina
#
# Configuration is handled via ~/.config/zsh-patina/config.toml.

# requires
zstyle ':zdot:brew' verify-tools zsh-patina
zstyle ':zdot:apt' verify-tools zsh-patina

_patina_init() {
    command -v zsh-patina &>/dev/null || {
        zdot_verbose "patina: zsh-patina not found, skipping"
        return 0
    }

    eval "$(zsh-patina activate)"
}

zdot_register_hook _patina_init interactive \
    --name patina \
    --requires xdg-configured prompt-ready \
    --requires-group patina-configure \
    --requires-tool zsh-patina \
    --provides patina-ready \
    --optional

zdot_register_completion_file "zsh-patina" "zsh-patina completion"
