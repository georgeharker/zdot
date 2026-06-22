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

# Completion registration lives in its OWN eager hook, separate from _patina_init
# (which activates zsh-patina at prompt time — gated on prompt-ready, deferred).
# Making _patina_init a completions-producer would force-defer completion
# finalization (and compinit) behind the prompt lifecycle. Registration only needs
# the binary available, so gate this hook on --requires-tool zsh-patina (provided
# eagerly by _brew_init, after PATH setup) and keep it eager: it joins
# completions-producers without dragging in the prompt phase. Cannot register at
# module-source time — the brew PATH isn't set up yet, so zsh-patina isn't found.
_patina_register_completions() {
    zdot_register_completion_file "zsh-patina" "zsh-patina completion"
}

zdot_register_hook _patina_register_completions interactive \
    --name patina-completions \
    --requires bootstrap-ready \
    --requires-tool zsh-patina \
    --group completions-producers \
    --optional

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
