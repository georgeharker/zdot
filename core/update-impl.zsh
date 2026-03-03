# core/update-impl.zsh
# zdot update implementation — pure functions, no side effects at source time.
#
# Callers must:
#   1. Set ZDOT_DIR before sourcing this file.
#   2. Source update_core.sh (provides _update_core_* helpers) before sourcing
#      this file, OR ensure it is already loaded in the current shell.
#   3. Define the logging shims  warn / info / error / verbose  before sourcing
#      this file (or after — they are only called at runtime, not source time).
#
# Entry points for callers:
#   _zdot_update_find_dotfiler_scripts   → REPLY = scripts dir; rc 0/1
#   _zdot_update_apply <old> <new>       → apply link-tree changes for a range
#   _zdot_update_standalone_apply        → pull + apply (standalone topology)
#   _zdot_update_submodule_apply         → submodule update + apply
#   _zdot_update_subtree_apply           → subtree pull + apply
#   _zdot_update_handle_update           → top-level shell-hook orchestrator

# ---------------------------------------------------------------------------
# dotfiler scripts detection (3-step priority)
# ---------------------------------------------------------------------------
# Sets REPLY to the dotfiler scripts directory; returns 0 on success, 1 if not
# found.  Requires both setup.sh (unpacker) and update.sh (range-mode updater).

_zdot_update_find_dotfiler_scripts() {
    local _candidate

    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate
    if [[ -n "$_candidate" && -f "$_candidate/setup.sh" && -f "$_candidate/update.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    # 2. Inside a parent repo that already has dotfiler scripts.
    #    _update_core_get_parent_root handles the superproject-then-toplevel
    #    fallback so we get the real parent root whether ZDOT_DIR is a
    #    submodule, standalone, subtree, or subdir repo.
    local _root
    _update_core_get_parent_root "$ZDOT_DIR"; _root=$REPLY
    if [[ -n "$_root" && -f "$_root/.nounpack/dotfiler/setup.sh" \
                       && -f "$_root/.nounpack/dotfiler/update.sh" ]]; then
        REPLY="$_root/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache — clone on demand if not yet present.
    #    zdot_use_bundle registered this repo at source time (for opted-in
    #    users) so the clone will not be treated as an orphan.
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="$_cache/georgeharker/dotfiler"
    if [[ ! -f "$_candidate/setup.sh" || ! -f "$_candidate/update.sh" ]]; then
        # Only attempt clone if zdot_plugin_clone is available (shell context)
        if (( ${+functions[zdot_plugin_clone]} )); then
            zdot_info "zdot: cloning dotfiler for update scripts..."
            zdot_plugin_clone "georgeharker/dotfiler" 2>/dev/null
        fi
    fi
    if [[ -f "$_candidate/setup.sh" && -f "$_candidate/update.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    REPLY=""; return 1
}

# ---------------------------------------------------------------------------
# Apply link-tree changes for a commit range
# ---------------------------------------------------------------------------
# Delegates to dotfiler's update.sh --range so all commit-walk / file-list
# logic lives in one place.

_zdot_update_apply() {
    local _old=$1 _new=$2

    # Respect link-tree zstyle (default: true)
    local _link_tree
    zstyle -s ':zdot:update' link-tree _link_tree || _link_tree=true
    [[ "$_link_tree" == false ]] && return 0

    local _scripts_dir _destdir
    zstyle -s ':zdot:update' destdir _destdir
    : ${_destdir:=${XDG_CONFIG_HOME:-$HOME/.config}/zdot}

    _zdot_update_find_dotfiler_scripts || {
        warn "zdot: update aborted — could not find or clone dotfiler scripts"
        return 1
    }
    _scripts_dir=$REPLY

    if [[ ! -x "$_scripts_dir/update.sh" ]]; then
        warn "zdot: update aborted — $_scripts_dir/update.sh not found or not executable"
        return 1
    fi

    "$_scripts_dir/update.sh" \
        --repo-dir "$ZDOT_DIR" \
        --link-dest "$_destdir" \
        --range "${_old}..${_new}"
}

# ---------------------------------------------------------------------------
# Topology-specific apply functions
# ---------------------------------------------------------------------------

_zdot_update_standalone_apply() {
    local _remote _branch _old _new
    _remote=$(_update_core_get_default_remote "$ZDOT_DIR")
    _branch=$(_update_core_get_default_branch "$ZDOT_DIR" "$_remote")
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    git -C "$ZDOT_DIR" pull -q "$_remote" "$_branch" || {
        warn "zdot: update failed — possibly modified files in the way"
        return 1
    }

    _zdot_update_apply "$_old" "$_new"
}

_zdot_update_submodule_apply() {
    local _zdot_real _parent_real _rel _remote _branch _old _new
    # Returns 0 only when ZDOT_DIR is a registered submodule.
    _update_core_get_parent_root "$ZDOT_DIR" || return 1
    _zdot_real=${ZDOT_DIR:A}
    _parent_real=$REPLY
    _rel=${_zdot_real#${_parent_real}/}
    _remote=$(_update_core_get_default_remote "$ZDOT_DIR")
    _branch=$(_update_core_get_default_branch "$ZDOT_DIR" "$_remote")
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    git -C "$_parent_real" submodule update --remote -- "$_rel" || {
        warn "zdot: submodule update failed"
        return 1
    }

    _zdot_update_apply "$_old" "$_new"
    local _itc_mode; zstyle -s ':zdot:update' in-tree-commit _itc_mode
    _update_core_commit_parent "$_parent_real" "$_rel" \
        "submodule pointer updated" \
        "zdot: update submodule to ${_new[1,12]}" \
        "$_itc_mode"
}

_zdot_update_subtree_apply() {
    local _parent_root _zdot_real _parent_real _rel
    local _subtree_spec _remote _branch _old _new

    # For subtree topology ZDOT_DIR is NOT a submodule, so --show-toplevel
    # correctly returns the parent repo root.
    _parent_root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
    _zdot_real=${ZDOT_DIR:A}
    _parent_real=${_parent_root:A}
    _rel=${_zdot_real#${_parent_real}/}

    zstyle -s ':zdot:update' subtree-remote _subtree_spec || {
        warn "zdot: subtree-remote zstyle not set"
        return 1
    }
    _remote=${_subtree_spec%% *}
    _branch=${_subtree_spec#* }
    [[ -z "$_remote" || -z "$_branch" || "$_branch" == "$_remote" ]] && {
        warn "zdot: subtree-remote must be 'remote branch' (space-separated)"
        return 1
    }

    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1

    git -C "$_parent_real" subtree pull --prefix="$_rel" "$_remote" "$_branch" --squash || {
        warn "zdot: subtree pull failed"
        return 1
    }

    # Record the remote SHA so future is_available_subtree can compare.
    local _remote_url _pulled_sha
    _remote_url=$(git -C "$ZDOT_DIR" config "remote.${_remote}.url" 2>/dev/null)
    _pulled_sha=$(_update_core_resolve_remote_sha "$_remote_url" "$_branch" 2>/dev/null)
    [[ -n "$_pulled_sha" ]] && _update_core_write_sha_marker "$ZDOT_DIR" "$_pulled_sha"

    _new=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    _zdot_update_apply "$_old" "$_new"

    local _itc_mode; zstyle -s ':zdot:update' in-tree-commit _itc_mode
    # Stage SHA marker alongside the subtree pointer when committing.
    _update_core_sha_marker_path "$ZDOT_DIR"
    local _marker_path=$REPLY
    if [[ "$_itc_mode" != "none" && -f "$_marker_path" ]]; then
        git -C "$_parent_real" add "$_marker_path" 2>/dev/null
    fi

    _update_core_commit_parent "$_parent_real" "$_rel" \
        "subtree updated" "zdot: update subtree ${_rel}" "$_itc_mode"
}

# ---------------------------------------------------------------------------
# Top-level shell-hook orchestrator
# ---------------------------------------------------------------------------
# Called by the zdot hook system at shell startup (interactive shells only).
# Performs frequency check, lock, update-available check, and mode dispatch.

_zdot_update_handle_update() {
    # 1. Read mode; exit immediately if disabled (default)
    local _mode
    zstyle -s ':zdot:update' mode _mode
    [[ "${_mode:-disabled}" == disabled ]] && return 0

    # 2. Early-exit guards
    [[ -n "$ZDOT_DIR" && -d "$ZDOT_DIR" ]] || return 0
    command -v git &>/dev/null || return 0
    git -C "$ZDOT_DIR" rev-parse --is-inside-work-tree &>/dev/null || return 0

    # 3. Acquire lock (prevents concurrent shells racing)
    local _lock_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/update.lock"
    _update_core_acquire_lock "$_lock_dir" || return 0

    # 4. Frequency check
    local _ts _freq _now _last_epoch=0
    _ts="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zdot_update"
    [[ -f "$_ts" ]] && { local LAST_EPOCH=0; source "$_ts" 2>/dev/null; _last_epoch=$LAST_EPOCH; }
    zstyle -s ':zdot:update' frequency _freq; : ${_freq:=3600}
    _now=$(_update_core_current_epoch)
    if (( _now - _last_epoch < _freq )); then
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 5. Detect topology; check for update
    local _subtree_spec
    zstyle -s ':zdot:update' subtree-remote _subtree_spec
    _update_core_detect_deployment "$ZDOT_DIR" "$_subtree_spec"
    local _deploy=$REPLY

    local _avail
    if [[ "$_deploy" == subtree && -n "$_subtree_spec" ]]; then
        local _st_remote=${_subtree_spec%% *}
        local _st_branch=${_subtree_spec#* }
        [[ "$_st_branch" == "$_st_remote" ]] && _st_branch=""
        [[ -z "$_st_branch" ]] && \
            _st_branch=$(_update_core_get_default_branch "$ZDOT_DIR" "$_st_remote")
        local _st_remote_url
        _st_remote_url=$(git -C "$ZDOT_DIR" config "remote.${_st_remote}.url" 2>/dev/null)
        _update_core_is_available_subtree "$ZDOT_DIR" "$_st_remote_url" "$_st_branch"
        _avail=$?
    else
        _update_core_is_available "$ZDOT_DIR"
        _avail=$?
    fi

    if (( _avail != 0 )); then
        _update_core_write_timestamp "$_ts" $(( _avail == 2 ? _avail : 0 )) ""
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 6. Subdir mode — parent repo manages updates
    if [[ "$_deploy" == subdir ]]; then
        zdot_info "zdot: update available but zdot is a tracked subdir of a parent repo."
        zdot_info "zdot: the parent repo manages updates; consider:"
        zdot_info "zdot:   zstyle ':zdot:update' mode disabled"
        _update_core_write_timestamp "$_ts" 0 ""
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 7. Dispatch by topology
    local _pull_fn
    case $_deploy in
        submodule)  _pull_fn=_zdot_update_submodule_apply ;;
        subtree)    _pull_fn=_zdot_update_subtree_apply   ;;
        *)          _pull_fn=_zdot_update_standalone_apply ;;
    esac

    # 8. Dispatch by mode
    case $_mode in
        reminder)
            zdot_info "zdot: update available (run: git -C \$ZDOT_DIR pull)"
            _update_core_write_timestamp "$_ts" 0 ""
            ;;
        auto)
            $_pull_fn
            _update_core_write_timestamp "$_ts" $? ""
            ;;
        prompt)
            if [[ -t 1 ]] && ! _update_core_has_typed_input; then
                print -n "zdot: update available. Pull now? [Y/n] "
                local _ans
                read -r -k1 _ans; print ""
                if [[ "$_ans" != (n|N) ]]; then
                    $_pull_fn
                    _update_core_write_timestamp "$_ts" $? ""
                fi
            fi
            ;;
    esac

    _update_core_release_lock "$_lock_dir"
}


# ---------------------------------------------------------------------------
# Cleanup: unset all functions defined in this file.
# Called by update.zsh's _zdot_update_cleanup after the shell hook is wired.
# Note: _zdot_update_handle_update is intentionally NOT unset here — it is
# kept alive as the shell hook body.
# ---------------------------------------------------------------------------

_zdot_update_impl_cleanup() {
    unset -f \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_apply \
        _zdot_update_standalone_apply \
        _zdot_update_submodule_apply \
        _zdot_update_subtree_apply \
        _zdot_update_impl_cleanup \
        2>/dev/null
}
