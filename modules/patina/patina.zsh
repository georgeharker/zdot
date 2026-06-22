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

# Register the completion at module-source time (like uv), NOT inside _patina_init.
# Registration is metadata and only needs the zsh-patina binary present, not
# active — so it must not ride on _patina_init, which is prompt-time (deferred via
# prompt-ready). Making that hook a completions-producer would force-defer
# completion finalization (and compinit) behind the prompt lifecycle. Top-level
# registration always precedes finalization, so no group membership is needed.
command -v zsh-patina &>/dev/null && \
    zdot_register_completion_file "zsh-patina" "zsh-patina completion"

_patina_init() {
    command -v zsh-patina &>/dev/null || {
        zdot_verbose "patina: zsh-patina not found, skipping"
        return 0
    }

    eval "$(zsh-patina activate)"
}

zdot_register_hook _patina_init interactive \
    --name patina \
    --requires bootstrap-ready prompt-ready \
    --requires-group patina-configure \
    --requires-tool zsh-patina \
    --provides patina-ready \
    --after autosuggestions-ready \
    --optional
