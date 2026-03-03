#!/usr/bin/env zsh
# core/dotfiler-hook.zsh
# zdot update hook — thin dispatcher for the dotfiler hook system.
#
# Installed into the dotfiler hooks directory as a symlink pointing back here.
# Because dotfiler invokes hooks as direct executables (never via `zsh -c`),
# %x is the symlink path and :A resolves it to this file's real location,
# giving us ZDOT_DIR reliably without any stub or pre-set variable.
#
# Interface (called by dotfiler's check_update.sh / update.sh):
#   zdot.zsh check-update            → 0 available | 1 up-to-date | 2 error
#   zdot.zsh apply-update            → 0 applied   | 1 nothing    | 2 error
#   zdot.zsh apply-update --dry-run

emulate -L zsh
setopt pipe_fail no_unset

# Self-location: :A resolves the symlink to the real file inside ZDOT_DIR/core/
ZDOT_DIR="${${${(%):-%x}:A}:h:h}"

# ---------------------------------------------------------------------------
# Locate and source update_core.sh
# Priority: 1. zstyle override  2. parent repo .nounpack/dotfiler  3. plugin cache
# ---------------------------------------------------------------------------
_zdot_hook_find_update_core() {
    local _candidate

    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate 2>/dev/null
    if [[ -n "$_candidate" && -f "$_candidate/update_core.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    # 2. Parent repo (superproject-then-toplevel fallback, same as update_core logic)
    local _root
    _root=$(git -C "$ZDOT_DIR" rev-parse --show-superproject-working-tree 2>/dev/null)
    [[ -z "$_root" ]] && \
        _root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$_root" && -f "$_root/.nounpack/dotfiler/update_core.sh" ]]; then
        REPLY="$_root/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="${_cache}/georgeharker/dotfiler"
    if [[ -f "$_candidate/update_core.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    REPLY=""; return 1
}

_zdot_hook_find_update_core || {
    print "zdot dotfiler-hook: could not find update_core.sh" >&2
    exit 2
}
unset -f _zdot_hook_find_update_core

source "${REPLY}/update_core.sh" || exit 2

# ---------------------------------------------------------------------------
# Logging shims (update_core.sh + update-impl.zsh use warn/info/verbose/error)
# ---------------------------------------------------------------------------
warn()    { print "zdot-hook: $*" >&2; }
info()    { print "zdot-hook: $*"; }
error()   { print "zdot-hook: $*" >&2; }
verbose() { [[ -n "${DOTFILES_DEBUG:-}" ]] && print "zdot-hook[v]: $*"; }

# ---------------------------------------------------------------------------
# Source shared implementation
# ---------------------------------------------------------------------------
# update-impl.zsh uses $ZDOT_DIR; bridge from the hook's $ZDOT_DIR.
source "${ZDOT_DIR}/core/update-impl.zsh" || exit 2

# ---------------------------------------------------------------------------
# check-update verb
# ---------------------------------------------------------------------------
_zdot_hook_check_update() {
    # allow_diverged=1: dotfiler will call apply-update on rc=0, and git pull
    # handles diverged histories via merge — so report diverged as available.
    _update_core_is_available "$ZDOT_DIR" "" 1
}

# ---------------------------------------------------------------------------
# apply-update verb
# ---------------------------------------------------------------------------
_zdot_hook_apply_update() {
    local _dry_run="${1:-}"
    local _subtree_spec
    zstyle -s ':zdot:update' subtree-remote _subtree_spec 2>/dev/null || _subtree_spec=""
    _update_core_detect_deployment "$ZDOT_DIR" "$_subtree_spec"
    local _deploy=$REPLY

    if [[ -n "$_dry_run" ]]; then
        # Delegate dry-run info to the relevant apply function via a dry_run flag;
        # but the apply functions don't take flags — so just check availability
        # and report what would happen.
        _zdot_hook_check_update || return $?
        info "dry-run: update available for topology=${_deploy}"
        return 0
    fi

    case $_deploy in
        standalone) _zdot_update_standalone_apply ;;
        submodule)  _zdot_update_submodule_apply  ;;
        subtree)    _zdot_update_subtree_apply     ;;
        subdir|*)   return 1                       ;;
    esac
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    check-update)  _zdot_hook_check_update ;;
    apply-update)  _zdot_hook_apply_update "${2:-}" ;;
    *)
        print "zdot dotfiler-hook: unknown verb '${1:-}'" >&2
        print "  usage: $(basename $0) check-update | apply-update [--dry-run]" >&2
        exit 2
        ;;
esac
