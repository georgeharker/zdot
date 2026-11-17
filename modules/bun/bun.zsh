#!/usr/bin/env zsh
# bun: Bun runtime / package manager — env, global-bin PATH, completions
#
# Bun itself is expected to come from a tool provider (brew/apt verify-tools,
# or the curl installer's ~/.bun/bin). This module does NOT install bun; it
# wires up what `bun add -g` produces so globals are runnable, and generates
# completions.
#
# Unlike nvm there is nothing slow to defer: bun is a single static binary and
# needs no per-shell activation, so there is no lazy-load / `use` step.
#
# zstyle (all optional; set from a bun-configure group hook or .zshrc):
#   zstyle ':zdot:bun' install-dir <dir>   Exported as BUN_INSTALL. Unset leaves
#                                          bun's own default resolution alone.
#   zstyle ':zdot:bun' global-bin  <dir>   Dir prepended/appended to PATH.
#                                          Default: bun's resolution (below).
#   zstyle ':zdot:bun' path-position <prepend|append>   (default: append)
#   zstyle ':zdot:bun' dns-ipv4 <yes|no>   BUN_DNS_USE_IPV4 (default: yes)

# ============================================================================
# Configuration
# ============================================================================

_bun_configure() {
    local install_dir
    zstyle -s ':zdot:bun' install-dir install_dir \
        && export BUN_INSTALL="${install_dir}"

    zstyle -T ':zdot:bun' dns-ipv4 && export BUN_DNS_USE_IPV4=1
}

# _bun_global_bin — REPLY = dir that `bun add -g` links executables into.
# Mirrors bun's own resolution (what `bun pm bin -g` prints) without spawning
# bun at startup: BUN_INSTALL_BIN, then $BUN_INSTALL/bin, then
# $XDG_CACHE_HOME/.bun/bin, then ~/.bun/bin.
_bun_global_bin() {
    zstyle -s ':zdot:bun' global-bin REPLY && return 0
    if [[ -n "$BUN_INSTALL_BIN" ]]; then
        REPLY="$BUN_INSTALL_BIN"
    elif [[ -n "$BUN_INSTALL" ]]; then
        REPLY="$BUN_INSTALL/bin"
    elif [[ -n "$XDG_CACHE_HOME" ]]; then
        REPLY="$XDG_CACHE_HOME/.bun/bin"
    else
        REPLY="$HOME/.bun/bin"
    fi
}

# ============================================================================
# Load: PATH + completions
# ============================================================================

_bun_load() {
    # Global bin on PATH. Created on demand by bun, so add it even if it
    # doesn't exist yet — otherwise the first `bun add -g` in a session
    # yields a command that isn't found until the next shell.
    _bun_global_bin
    local bin_dir="$REPLY" position
    zstyle -s ':zdot:bun' path-position position || position=append
    if (( ! ${path[(Ie)$bin_dir]} )); then
        # append (default): system/brew/nvm binaries win on name clashes;
        # nvm's `use` prepends its own bin later anyway.
        if [[ "$position" == prepend ]]; then
            path=("$bin_dir" $path)
        else
            path+=("$bin_dir")
        fi
    fi

    # Generated into the zdot completions dir by refresh_completions;
    # regenerated when the bun binary is newer than the cached _bun.
    zdot_register_completion_file "bun" "bun completions zsh"
}

# ============================================================================
# Module Definition
# ============================================================================

# --requires-optional-tool bun: brew/apt manifest bun best-effort; skip the
#   load hook (PATH + completions) cleanly when it isn't installed.
# --group completions-producers: _bun_load registers completions in its body,
#   so completions finalization must wait for it (see modules/completions).
# --auto-configure-group: exposes `bun-configure` (same group name the old
#   simple_hook used), so existing user hooks keep working.
zdot_define_module bun \
    --configure _bun_configure \
    --load _bun_load \
    --requires-optional-tool bun \
    --group completions-producers \
    --auto-configure-group
