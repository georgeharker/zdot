# core/dotfiler-hook.zsh
# zdot update hook for the dotfiler hook system.
#
# Installed into the dotfiler hooks directory as a symlink pointing back here.
# %x resolves (via :A) to this file's real location inside ZDOT_REPO/core/,
# giving us ZDOT_REPO reliably without any stub or pre-set variable.
#
# Always sourced — never exec'd.
# Callers (dotfiler's update.zsh and check_update.zsh) source this file directly.
# All _zdot_update_hook_* functions are defined in-process.
# _zdot_update_hook_register registers phase functions into the caller's registry
# via _update_register_hook (defined by the caller — real in update.zsh, shim in
# check_update.zsh). No DOTFILER_HOOK_MODE or branching needed.

# Self-location: :A resolves the symlink to the real backing repo inside ZDOT_REPO/core/
# ZDOT_DIR (the linktree path) must NOT be clobbered here — core.zsh sets it correctly.
ZDOT_REPO="${${${(%):-%x}:A}:h:h}"

# ---------------------------------------------------------------------------
# Logging shims
# Defined early so they are available during bootstrap (e.g. find_update_core).
# info/verbose → stdout (user-facing progress)
# warn/error   → stderr (diagnostics)
# ---------------------------------------------------------------------------
warn()      { print "zdot-hook: $*" >&2; return 0; }
info()      { print "zdot-hook: $*"; return 0; }
error()     { print "zdot-hook: $*" >&2; return 0; }
verbose() {
    [[ -n "${DOTFILER_VERBOSE:-}" ]] || [[ -n "${ZDOT_VERBOSE:-}" ]] \
        || return 0
    print -P "%F{cyan}[verbose]%f zdot-hook: $*"
    return 0
}
log_debug() {
    [[ -n "${DOTFILER_DEBUG:-}" ]] || [[ -n "${ZDOT_DEBUG:-}" ]] \
        || return 0
    print -P "%F{magenta}[debug]%f zdot-hook: $*"
    return 0
}

# ---------------------------------------------------------------------------
# Locate update_core.zsh
# Priority: 1. zstyle override  2. parent repo .nounpack/dotfiler  3. plugin cache
# ---------------------------------------------------------------------------
_zdot_hook_find_update_core() {
    local _candidate

    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate 2>/dev/null
    if [[ -n "$_candidate" && -f "$_candidate/update_core.zsh" ]]; then
        REPLY=$_candidate; return 0
    fi

    # 2. Parent repo (superproject-then-toplevel fallback)
    # Use ZDOT_REPO (real worktree) so git can resolve .git correctly.
    local _root
    _root=$(git -C "$ZDOT_REPO" \
        rev-parse --show-superproject-working-tree 2>/dev/null)
    [[ -z "$_root" ]] && \
        _root=$(git -C "$ZDOT_REPO" rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$_root" && -f "$_root/.nounpack/dotfiler/update_core.zsh" ]]; then
        REPLY="$_root/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="${_cache}/georgeharker/dotfiler"
    if [[ -f "$_candidate/update_core.zsh" ]]; then
        REPLY=$_candidate; return 0
    fi

    REPLY=""; return 1
}

_zdot_hook_find_update_core || {
    error "could not find update_core.zsh"
    return 2
}
_zdot_dotfiler_scripts_dir="$REPLY"
unset -f _zdot_hook_find_update_core

source "${_zdot_dotfiler_scripts_dir}/update_core.zsh" || return 2
# ---------------------------------------------------------------------------
# Source shared implementation (all hook logic lives here)
# ---------------------------------------------------------------------------
source "${ZDOT_DIR}/core/update-impl.zsh" || return 2

# ---------------------------------------------------------------------------
# Entry point — register phase functions into the caller's registry
# ---------------------------------------------------------------------------
_zdot_update_hook_register
