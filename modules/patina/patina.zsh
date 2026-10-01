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
# zstyle ':zdot:brew' verify-tools zsh-patina
# zstyle ':zdot:apt' verify-tools zsh-patina

# Completion registration lives in its OWN eager hook, separate from _patina_init
# (which activates zsh-patina at prompt time — gated on prompt-ready, deferred).
# Making _patina_init a completions-producer would force-defer completion
# finalization (and compinit) behind the prompt lifecycle. Registration only needs
# the binary available: gate the completions hook on --requires-optional-tool
# zsh-patina (registration happens eagerly via the brew manifest, and the
# gate skips it when the binary turns out not to be installed) and keep it
# eager: it joins completions-producers without dragging in the prompt phase.
# Cannot register at module-source time — the brew PATH isn't set up yet, so
# zsh-patina isn't found.
_patina_register_completions() {
    zdot_register_completion_file "zsh-patina" "zsh-patina completion"
}

zdot_register_hook _patina_register_completions interactive \
    --name patina-completions \
    --requires bootstrap-ready \
    --requires-optional-tool zsh-patina \
    --group completions-producers

_patina_init() {
    # Availability is gated declaratively: --requires-optional-tool skips this
    # hook when zsh-patina isn't on PATH (after the tool provider ran).

    eval "$(zsh-patina activate)"
}

# prompt-ready is --requires-optional, not --requires: zsh-patina wraps ZLE, so
# it should activate after the prompt is set up when a prompt module is loaded,
# but it highlights fine on its own. As a plain --requires it combined with
# --optional to SKIP patina entirely on a config with no prompt module; as
# --requires-optional, patina still activates there (just unordered re: a prompt).
# --requires-optional-tool, not a plain --requires-tool: zsh-patina wraps ZLE,
# so (a) availability gets its own gate — skip the hook when the binary ends up
# not installed after all; (b) prompt-ready stays --requires-optional instead
# of --requires so patina still activates when no prompt module is loaded
# (just unordered re: a prompt). A plain --requires-tool + --optional would
# additionally have skipped patina whenever no hook provides tool:zsh-patina,
# even when the binary is installed by hand (cargo install).
zdot_register_hook _patina_init interactive \
    --name patina \
    --requires bootstrap-ready \
    --requires-optional prompt-ready \
    --requires-group patina-configure \
    --requires-optional-tool zsh-patina \
    --provides patina-ready \
    --after autosuggestions-ready
