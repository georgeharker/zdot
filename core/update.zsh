# core/update.zsh
# zdot self-update — shell startup integration.
#
# Opt-in: set zstyle ':zdot:update' mode to prompt|auto|reminder to activate.
# Default mode is 'disabled' — zero overhead for users who do not opt in.
#
# zstyle reference:
#   zstyle ':zdot:update' mode                disabled   # disabled|reminder|prompt|auto
#   zstyle ':zdot:update' frequency           3600       # seconds between checks
#   zstyle ':zdot:update' destdir             "${XDG_CONFIG_HOME:-$HOME/.config}/zdot"
#   zstyle ':zdot:update' in-tree-commit      none       # none|prompt|auto
#   zstyle ':zdot:update' subtree-remote      ""         # "remote branch" for git subtree pull
#   zstyle ':zdot:update' link-tree           true       # false to skip link-tree unpacking
#   zstyle ':zdot:dotfiler' scripts-dir       ""         # auto-detected if empty
#   zstyle ':zdot:update' release-channel     release    # release|any
#
# release-channel controls which commits are considered as update targets
# (Phase 2 / self-directed checks only — Phase 1 dotfiles-directed is unaffected):
#   release (default) — only advance to commits reachable from a semver tag
#                    matching v<N>.<N>.<N>[...].  No qualifying tag = no update.
#   any            — advance to the branch tip (previous behaviour).
#
# Deployment scenarios:
#   standalone   — ZDOT_DIR is its own git root; zdot does git pull + apply
#   submodule    — ZDOT_DIR is a registered submodule inside a parent repo
#   subtree      — ZDOT_DIR is inside a parent repo and subtree-remote is set
#   subdir       — ZDOT_DIR is inside a parent repo, not a submodule, and
#                  subtree-remote is unset; parent repo manages updates
#   disabled     — mode=disabled; zdot no-ops

# ---------------------------------------------------------------------------
# Source shared implementation first — provides shell-side mirror functions
# (_zdot_update_get_parent_root, _zdot_update_find_dotfiler_scripts, etc.)
# that the rest of this file depends on at source time.
# ---------------------------------------------------------------------------
source "${ZDOT_DIR}/core/update-impl.zsh"

# ---------------------------------------------------------------------------
# Register dotfiler as a bundle dependency (opt-in users only).
# Must happen at source time so zdot_clean_plugins never treats the cloned
# dotfiler repo as an orphan.
# ---------------------------------------------------------------------------
{
    local _zdot_update_init_mode
    zstyle -s ':zdot:update' mode _zdot_update_init_mode
    if [[ "${_zdot_update_init_mode:-disabled}" != disabled ]]; then
        # Only register the plugin clone if dotfiler is not already present in
        # the parent repo — avoids a redundant clone when zdot is a submodule
        # or subtree inside a dotfiler-managed dotfiles repo.
        local _zdot_update_init_parent
        _zdot_update_get_parent_root "$ZDOT_REPO"
        _zdot_update_init_parent=${reply[1]}
        if [[ ! -f "${_zdot_update_init_parent}/.nounpack/dotfiler/update_core.zsh" ]]; then
            zdot_use_bundle "georgeharker/dotfiler"
        fi
    fi
}

# No logging shims needed here — update-impl.zsh uses zdot_* natively,
# and zdot_* functions are always defined in the zdot shell context.

# ---------------------------------------------------------------------------
# Bootstrap lookup — finds dotfiler scripts dir using raw git commands
# (update_core.zsh is not yet loaded).  Uses the same 3-step priority as
# _zdot_update_find_dotfiler_scripts but only checks for update_core.zsh.
# Uses _zdot_update_get_parent_root (from update-impl.zsh) for step 2.
# ---------------------------------------------------------------------------
_zdot_update_bootstrap_find_dotfiler() {
    local _candidate

    # 1. zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate 2>/dev/null
    if [[ -n "$_candidate" && -f "${_candidate}/update_core.zsh" ]]; then
        REPLY="$_candidate"; return 0
    fi

    # 2. Parent repo (via shell-side mirror — no update_core.zsh needed)
    local _parent
    _zdot_update_get_parent_root "$ZDOT_REPO"; _parent=${reply[1]}
    if [[ -n "$_parent" && -f "${_parent}/.nounpack/dotfiler/update_core.zsh" ]]; then
        REPLY="${_parent}/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="${_cache}/georgeharker/dotfiler"
    if [[ -f "${_candidate}/update_core.zsh" ]]; then
        REPLY="$_candidate"; return 0
    fi

    REPLY=""; return 1
}

{
    if _zdot_update_bootstrap_find_dotfiler; then
        _zdot_dotfiler_scripts_dir="$REPLY"
        # update_core.zsh is NOT sourced here — it is heavy and only needed at
        # hook-run time.  _zdot_update_shell_hook sources it inside a ( )
        # subshell which auto-cleans the entire namespace on exit.
    fi
}

# ---------------------------------------------------------------------------
# Cleanup: unset all private helpers after the hook is wired.
# _zdot_update_handle_update is kept — it IS the hook body.
# ---------------------------------------------------------------------------

_zdot_update_cleanup() {
    _zdot_update_impl_cleanup_shell
    # verbose/log_debug shims are NOT unset — runtime deps of _zdot_update_handle_update.
    unset -f _zdot_update_bootstrap_find_dotfiler 2>/dev/null
    unset -f _zdot_update_install_dotfiler_hook 2>/dev/null
    unset -f _zdot_update_cleanup 2>/dev/null
}

# ---------------------------------------------------------------------------
# Wire into zdot hook system and clean up private helpers
# ---------------------------------------------------------------------------
# Skip registering the shell-hook when dotfiler is managing zdot updates —
# dotfiler/update.zsh will drive the full update lifecycle (plan/pull/unpack/
# post) via the hook registered in dotfiler-hook.zsh. Registering here too
# would cause double update attempts.
#
# When not in dotfiler-integration mode, we register a thin wrapper that runs
# the update inside a subshell. The subshell sources setup_core.zsh first so
# that _zdot_update_hook_unpack has setup_core_main available, while keeping
# the interactive shell's namespace completely clean.
# _zdot_update_handle_update itself (in update-impl.zsh) is shared with the
# dotfiler hook path and must stay free of any shell-path setup logic.

_zdot_update_shell_hook() {
    # Run inside a ( ) subshell — everything sourced here (update_core.zsh,
    # setup_core.zsh) is automatically cleaned up when the subshell exits.
    # No explicit _update_core_cleanup needed.
    (
        # update_core.zsh provides the _update_core_* functions needed by
        # _zdot_update_handle_update (availability checks, locks, safe_rm, etc.)
        local _update_core="${_zdot_dotfiler_scripts_dir}/update_core.zsh"
        if [[ -f "$_update_core" ]]; then
            source "$_update_core"
        else
            zdot_warn "zdot: update_core.zsh not found at ${_update_core}, skipping update"
            return 1
        fi

        local _setup_core="${_zdot_dotfiler_scripts_dir}/setup_core.zsh"
        if [[ -f "$_setup_core" ]]; then
            source "$_setup_core"
        else
            zdot_warn "zdot: setup_core.zsh not found at ${_setup_core}, skipping update"
            return 1
        fi
        _zdot_update_handle_update
    )
}

if ! _zdot_update_is_dotfiler_integration; then
    zdot_register_hook _zdot_update_shell_hook \
        --name zdot-update \
        --context interactive \
        --group finally
fi

_zdot_update_cleanup
