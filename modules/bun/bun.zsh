#!/usr/bin/env zsh
# bun: Bun runtime / package manager — XDG dirs, global-bin PATH, completions
#
# Bun itself is expected to come from a tool provider (brew/apt verify-tools,
# or the curl installer). This module does NOT install bun; it places bun's
# state in XDG dirs, wires up what `bun add -g` produces so globals are
# runnable, and generates completions.
#
# Unlike nvm there is nothing slow to defer: bun is a single static binary and
# needs no per-shell activation, so there is no lazy-load / `use` step.
#
# XDG layout (default; `zstyle ':zdot:bun' xdg no` leaves bun's own defaults):
#   BUN_INSTALL            $XDG_DATA_HOME/bun   globals, curl-installed binary
#   BUN_INSTALL_CACHE_DIR  $XDG_CACHE_HOME/bun  download cache (disposable)
#   global bin             $BUN_INSTALL/bin     (bun's default under BUN_INSTALL)
# Without this, bun falls back to $XDG_CACHE_HOME/.bun when XDG_CACHE_HOME is
# set — i.e. global packages living in a cache dir that cleaners may wipe.
#
# Precedence for each dir: zstyle > variable already in the environment >
# XDG default. An existing legacy ~/.bun (or $XDG_CACHE_HOME/.bun) is kept as
# BUN_INSTALL when the XDG dir doesn't exist yet, so installed globals don't
# silently disappear; see README "Migrating" to move them.
#
# zstyle (all optional; set from a bun-configure group hook or .zshrc):
#   zstyle ':zdot:bun' xdg <yes|no>        XDG defaults (default: yes)
#   zstyle ':zdot:bun' install-dir <dir>   Exported as BUN_INSTALL
#   zstyle ':zdot:bun' cache-dir <dir>     Exported as BUN_INSTALL_CACHE_DIR
#   zstyle ':zdot:bun' global-bin  <dir>   Exported as BUN_INSTALL_BIN; on PATH.
#                                          Unset: whatever `bun pm bin -g`
#                                          says (honours the global bunfig's
#                                          install.globalBinDir)
#   zstyle ':zdot:bun' path-position <prepend|append>   (default: append)
#   zstyle ':zdot:bun' dns-ipv4 <yes|no>   BUN_DNS_USE_IPV4 (default: yes)

# ============================================================================
# Configuration
# ============================================================================

# _bun_default_install_dir — REPLY = XDG BUN_INSTALL, or a legacy dir that
# already holds an install when the XDG one doesn't exist yet.
_bun_default_install_dir() {
    local xdg_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/bun"
    local -a legacy=("${HOME}/.bun")
    [[ -n "$XDG_CACHE_HOME" ]] && legacy+=("${XDG_CACHE_HOME}/.bun")
    REPLY="$xdg_dir"
    [[ -d "$xdg_dir" ]] && return 0
    local d
    for d in "${legacy[@]}"; do
        # Only real globals or a binary count. Not the bare dir: even a
        # read-only `bun pm bin -g` creates an empty install/global.
        if [[ -f "$d/install/global/package.json" || -x "$d/bin/bun" ]]; then
            REPLY="$d"
            return 0
        fi
    done
}

# _bun_path_add <dir> — add to PATH honouring path-position, once.
_bun_path_add() {
    local dir="$1" position p
    # Same dir by identity, not just spelling: bun prints realpaths
    # (/private/tmp vs /tmp on macOS).
    for p in $path; do
        [[ "$p" == "$dir" || "$p" -ef "$dir" ]] && return 0
    done
    zstyle -s ':zdot:bun' path-position position || position=append
    if [[ "$position" == prepend ]]; then
        path=("$dir" $path)
    else
        path+=("$dir")
    fi
}

_bun_configure() {
    local dir
    if zstyle -s ':zdot:bun' install-dir dir; then
        export BUN_INSTALL="$dir"
    elif [[ -z "$BUN_INSTALL" ]] && zstyle -T ':zdot:bun' xdg; then
        _bun_default_install_dir
        export BUN_INSTALL="$REPLY"
    fi

    if zstyle -s ':zdot:bun' cache-dir dir; then
        export BUN_INSTALL_CACHE_DIR="$dir"
    elif [[ -z "$BUN_INSTALL_CACHE_DIR" ]] && zstyle -T ':zdot:bun' xdg; then
        export BUN_INSTALL_CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/bun"
    fi

    # Export, not just PATH: bun must link globals where PATH looks.
    zstyle -s ':zdot:bun' global-bin dir && export BUN_INSTALL_BIN="$dir"

    zstyle -T ':zdot:bun' dns-ipv4 && export BUN_DNS_USE_IPV4=1

    # A curl-installed bun lives in $BUN_INSTALL/bin. Put it on PATH here, in
    # configure, so the load hook's --requires-optional-tool gate can see it.
    [[ -n "$BUN_INSTALL" && -x "$BUN_INSTALL/bin/bun" ]] \
        && _bun_path_add "$BUN_INSTALL/bin"
    return 0
}

# _bun_global_bin — REPLY = dir that `bun add -g` links executables into, as
# bun itself resolves it (BUN_INSTALL_BIN, the global bunfig's
# install.globalBinDir, $BUN_INSTALL/bin, ...). ~4 ms per shell; only called
# from the load hook, which is gated on bun being on PATH. Run from / so a
# project's package.json / .env in the cwd can't get involved.
_bun_global_bin() {
    REPLY="$(cd / && bun pm bin -g 2>/dev/null)"
    [[ -n "$REPLY" ]]
}

# ============================================================================
# Load: PATH + completions
# ============================================================================

_bun_load() {
    # Global bin on PATH, as bun reports it (`bun pm bin -g` also creates it,
    # so the first `bun add -g` in a session is runnable straight away).
    # append (default): system/brew/nvm binaries win on name clashes;
    # nvm's `use` prepends its own bin later anyway.
    _bun_global_bin && _bun_path_add "$REPLY"

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
