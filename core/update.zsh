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
#
# Deployment scenarios:
#   standalone   — ZDOT_DIR is its own git root; zdot does git pull + apply
#   submodule    — ZDOT_DIR is a registered submodule inside a parent repo
#   subtree      — ZDOT_DIR is inside a parent repo and subtree-remote is set
#   subdir       — ZDOT_DIR is inside a parent repo, not a submodule, and
#                  subtree-remote is unset; parent repo manages updates
#   disabled     — mode=disabled; zdot no-ops

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
        _zdot_update_init_parent=$(
            git -C "$ZDOT_REPO" rev-parse --show-superproject-working-tree 2>/dev/null)
        [[ -z "$_zdot_update_init_parent" ]] && \
            _zdot_update_init_parent=$(
                git -C "$ZDOT_REPO" rev-parse --show-toplevel 2>/dev/null)
        if [[ ! -f "${_zdot_update_init_parent}/.nounpack/dotfiler/update_core.sh" ]]; then
            zdot_use_bundle "georgeharker/dotfiler"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Logging shims — map update_core.sh log functions to zdot equivalents.
# Defined before sourcing update_core.sh / update-impl.zsh so that any
# logging during source is routed correctly.
# Removed by _zdot_update_cleanup after the shell hook is registered.
# ---------------------------------------------------------------------------
warn()    { zdot_warn "$@"; }
info()    { zdot_info "$@"; }
error()   { zdot_warn "$@"; }
verbose() { zdot_verbose "%F{cyan}[debug]%f $*"; }

# ---------------------------------------------------------------------------
# Source update_core.sh shared primitives
# 3-step priority matching dotfiler-hook.zsh:
#   1. zstyle ':zdot:dotfiler' scripts-dir override
#   2. Parent repo .nounpack/dotfiler
#   3. Plugin cache
# ---------------------------------------------------------------------------
{
    local _zdot_update_core_dir=""

    # 1. zstyle override
    local _zdot_update_zstyle_dir
    zstyle -s ':zdot:dotfiler' scripts-dir _zdot_update_zstyle_dir 2>/dev/null
    if [[ -n "$_zdot_update_zstyle_dir" \
       && -f "${_zdot_update_zstyle_dir}/update_core.sh" ]]; then
        _zdot_update_core_dir="$_zdot_update_zstyle_dir"
    fi

    # 2. Parent repo
    if [[ -z "$_zdot_update_core_dir" ]]; then
        local _zdot_update_parent
        _zdot_update_parent=$(
            git -C "$ZDOT_REPO" rev-parse --show-superproject-working-tree 2>/dev/null)
        [[ -z "$_zdot_update_parent" ]] && \
            _zdot_update_parent=$(
                git -C "$ZDOT_REPO" rev-parse --show-toplevel 2>/dev/null)
        if [[ -f "${_zdot_update_parent}/.nounpack/dotfiler/update_core.sh" ]]; then
            _zdot_update_core_dir="${_zdot_update_parent}/.nounpack/dotfiler"
        fi
    fi

    # 3. Plugin cache
    if [[ -z "$_zdot_update_core_dir" ]]; then
        local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
        local _candidate="${_cache}/georgeharker/dotfiler"
        [[ -f "${_candidate}/update_core.sh" ]] && \
            _zdot_update_core_dir="$_candidate"
    fi

    if [[ -n "$_zdot_update_core_dir" ]]; then
        _zdot_dotfiler_scripts_dir="$_zdot_update_core_dir"
        source "${_zdot_update_core_dir}/update_core.sh" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Source shared implementation
# ---------------------------------------------------------------------------
source "${ZDOT_DIR}/core/update-impl.zsh"

# ---------------------------------------------------------------------------
# Hook self-installation
# ---------------------------------------------------------------------------
# When zdot is running inside a dotfiler-managed repo, write a stub hook
# script into the dotfiler hooks directory.  Uses ZDOT_REPO (the real backing
# repo path, symlinks resolved) so git operations work correctly regardless of
# whether the linktree has a symlinked .git file.
# Runs at source time; cheap ([[ -f ]] checks only).

_zdot_update_install_dotfiler_hook() {
    # Only install if _update_core_get_parent_root is available (update_core.sh loaded)
    (( ${+functions[_update_core_get_parent_root]} )) || return 0

    _update_core_get_parent_root "$ZDOT_REPO"
    local _parent_root=${reply[1]}
    [[ -f "${_parent_root}/.nounpack/dotfiler/update_core.sh" ]] || return 0

    local _hooks_dir
    zstyle -s ':dotfiler:hooks' dir _hooks_dir \
        || _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    [[ -d "$_hooks_dir" ]] || mkdir -p "$_hooks_dir" 2>/dev/null || return 0

    local _hook_src="${ZDOT_REPO}/core/dotfiler-hook.zsh"
    [[ -f "$_hook_src" ]] || return 0

    local _hook_link="${_hooks_dir}/zdot.zsh"

    # Install/update symlink — dotfiler sources hooks (not exec's them),
    # so no +x needed. %x:A in dotfiler-hook.zsh resolves the symlink correctly.
    local _current
    [[ -L "$_hook_link" ]] && _current=$(readlink "$_hook_link" 2>/dev/null)
    if [[ "$_current" != "$_hook_src" ]]; then
        ln -sf "$_hook_src" "$_hook_link" 2>/dev/null
    fi
}

{
    _zdot_update_install_dotfiler_hook
}

# ---------------------------------------------------------------------------
# Cleanup: unset all private helpers after the hook is wired.
# _zdot_update_handle_update is kept — it IS the hook body.
# ---------------------------------------------------------------------------

_zdot_update_cleanup() {
    # Unset functions defined in update-impl.zsh that are not needed at runtime
    { (( ${+functions[_zdot_update_impl_cleanup_shell]} )) \
        && _zdot_update_impl_cleanup_shell; } 2>/dev/null || true
    # Unset functions local to this file
    unset -f \
        _zdot_update_install_dotfiler_hook \
        warn info error verbose \
        2>/dev/null
    # _update_core_* functions are NOT cleaned up here: they are runtime
    # dependencies of _zdot_update_handle_update (via _zdot_update_hook_*).
    # _update_core_cleanup is for update.sh (subprocess) use only.
    unset -f _zdot_update_cleanup 2>/dev/null
}

# ---------------------------------------------------------------------------
# Wire into zdot hook system and clean up private helpers
# ---------------------------------------------------------------------------

zdot_register_hook _zdot_update_handle_update \
    --name zdot-update \
    --context interactive \
    --group finally

_zdot_update_cleanup
