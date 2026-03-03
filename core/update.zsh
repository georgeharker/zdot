# core/update.zsh
# zdot self-update mechanism
#
# Opt-in: set zstyle ':zdot:update' mode to prompt|auto|reminder to activate.
# Default mode is 'disabled' — zero overhead for users who do not opt in.
#
# zstyle reference:
#   zstyle ':zdot:update' mode                disabled   # disabled|reminder|prompt|auto
#   zstyle ':zdot:update' frequency           3600       # seconds between checks
#   zstyle ':zdot:update' destdir             "${XDG_CONFIG_HOME:-$HOME/.config}/zdot"
#   zstyle ':zdot:update' in-tree-commit        none       # none|prompt|auto
#   zstyle ':zdot:update' subtree-remote      ""         # "remote branch" for git subtree pull
#   zstyle ':zdot:dotfiler' scripts-dir       ""         # auto-detected if empty
#
# Deployment scenarios:
#   standalone   — ZDOT_DIR is its own git root; zdot does git pull + apply
#   submodule    — ZDOT_DIR is a registered submodule inside a parent repo;
#                  zdot does git submodule update --remote + apply + pointer handling
#   subtree      — ZDOT_DIR is inside a parent repo (not a submodule) and
#                  subtree-remote is set; zdot does git subtree pull + apply
#   subdir       — ZDOT_DIR is inside a parent repo but not a submodule and
#                  subtree-remote is unset; parent repo manages updates; zdot no-ops
#   disabled     — mode=disabled, or dotfiler handles everything; zdot no-ops

# ---------------------------------------------------------------------------
# Register dotfiler as a bundle dependency (opt-in users only).
# This must happen at source time so zdot_clean_plugins never treats the
# cloned dotfiler repo as an orphan.  The actual clone is deferred until an
# update is first applied.
# ---------------------------------------------------------------------------
{
    local _zdot_update_init_mode
    zstyle -s ':zdot:update' mode _zdot_update_init_mode
    if [[ "${_zdot_update_init_mode:-disabled}" != disabled ]]; then
        zdot_use_bundle "georgeharker/dotfiler"
    fi
}

# ---------------------------------------------------------------------------
# dotfiler scripts detection (3-step priority) — must be defined first so the
# shim+source block below can call it.
# ---------------------------------------------------------------------------

_zdot_update_find_dotfiler_scripts() {
    # Sets REPLY to the dotfiler scripts/ dir path; returns 0 on success, 1 if not found.
    # Requires both setup.sh (unpacker) and update.sh (range-mode updater).
    local _candidate

    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate
    if [[ -n "$_candidate" && -f "$_candidate/setup.sh" && -f "$_candidate/update.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    # 2. Inside a parent repo that already has dotfiler scripts
    local _root
    _root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$_root" && -f "$_root/.nounpack/dotfiler/setup.sh" && -f "$_root/.nounpack/dotfiler/update.sh" ]]; then
        REPLY="$_root/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache path — clone on demand if not yet present.
    # zdot_use_bundle already registered this repo at source time (for opted-in users)
    # so the clone will not be treated as an orphan by zdot_clean_plugins.
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="$_cache/georgeharker/dotfiler"
    if [[ ! -f "$_candidate/setup.sh" || ! -f "$_candidate/update.sh" ]]; then
        zdot_info "zdot: cloning dotfiler for update scripts..."
        zdot_plugin_clone "georgeharker/dotfiler" 2>/dev/null
    fi
    if [[ -f "$_candidate/setup.sh" && -f "$_candidate/update.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    REPLY=""; return 1
}

# ---------------------------------------------------------------------------
# Logging shim + source update_core.sh shared primitives
# ---------------------------------------------------------------------------
# Map update_core.sh log functions to zdot equivalents, then source the lib.
# These shims are added to the cleanup unset list so they are removed after
# _zdot_update_handle_update has run.
warn()    { zdot_warn "$@"; }
info()    { zdot_info "$@"; }
error()   { zdot_warn "$@"; }
verbose() { zdot_verbose "$@"; }

{
    local _zdot_update_dotfiler_scripts
    if _zdot_update_find_dotfiler_scripts 2>/dev/null; then
        _zdot_update_dotfiler_scripts=$REPLY
        source "$_zdot_update_dotfiler_scripts/update_core.sh" 2>/dev/null || true
    fi
}

_zdot_update_apply() {
    # Delegate to dotfiler's update.sh in --range mode.
    # update.sh handles: build file lists, delete removed symlinks, unpack via setup.sh.
    # This avoids duplicating the commit-walking / file-list logic here.
    local _old=$1 _new=$2
    local _scripts_dir _destdir

    zstyle -s ':zdot:update' destdir _destdir
    : ${_destdir:=${XDG_CONFIG_HOME:-$HOME/.config}/zdot}

    _zdot_update_find_dotfiler_scripts || {
        zdot_warn "zdot: update aborted — could not find or clone dotfiler scripts"
        zdot_warn "      Tried: zstyle ':zdot:dotfiler' scripts-dir, parent repo, plugin cache"
        zdot_warn "      Fix:   zstyle ':zdot:dotfiler' scripts-dir /path/to/dotfiler/scripts"
        zdot_warn "          or ensure network access so dotfiler can be cloned automatically"
        return 1
    }
    _scripts_dir=$REPLY

    if [[ ! -x "$_scripts_dir/update.sh" ]]; then
        zdot_warn "zdot: update aborted — $_scripts_dir/update.sh not found or not executable"
        return 1
    fi

    "$_scripts_dir/update.sh" \
        --repo-dir "$ZDOT_DIR" \
        --link-dest "$_destdir" \
        --range "${_old}..${_new}"
}

# ---------------------------------------------------------------------------
# Pull paths: standalone and submodule
# ---------------------------------------------------------------------------

_zdot_update_standalone_apply() {
    # Matches update.sh's order exactly:
    # 1. fetch (already done by _zdot_update_is_available, but remote ref is current)
    # 2. compute range from pre-pull HEAD to remote ref
    # 3. walk commits rev-by-rev to build file lists
    # 4. pull
    # 5. apply file lists
    local _remote _branch _old _new
    _remote=$(_update_core_get_default_remote "$ZDOT_DIR")
    _branch=$(_update_core_get_default_branch "$ZDOT_DIR" "$_remote")
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    # Pull
    git -C "$ZDOT_DIR" pull -q "$_remote" "$_branch" || {
        zdot_warn "zdot: update failed — possibly modified files in the way"
        return 1
    }

    _zdot_update_apply "$_old" "$_new"
}

_zdot_update_submodule_apply() {
    # Same order: compute range pre-update, update, then apply.
    local _parent_root _zdot_real _parent_real _rel _remote _branch _old _new
    _parent_root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
    _zdot_real=${ZDOT_DIR:A}
    _parent_real=${_parent_root:A}
    _rel=${_zdot_real#${_parent_real}/}
    _remote=$(_update_core_get_default_remote "$ZDOT_DIR")
    _branch=$(_update_core_get_default_branch "$ZDOT_DIR" "$_remote")
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    git -C "$_parent_real" submodule update --remote -- "$_rel" || {
        zdot_warn "zdot: submodule update failed"
        return 1
    }

    _zdot_update_apply "$_old" "$_new"
    local _itc_mode; zstyle -s ':zdot:update' in-tree-commit _itc_mode
    _update_core_commit_parent "$_parent_real" "$_rel" "submodule pointer updated" "zdot: update submodule to ${_new[1,12]}" "$_itc_mode"
}

_zdot_update_subtree_apply() {
    # Subtree pull: fetch from the configured remote/branch, squash-merge
    # into the parent repo, then apply zdot's changed-file hooks.
    local _parent_root _zdot_real _parent_real _rel _subtree_spec _remote _branch _old _new
    _parent_root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
    _zdot_real=${ZDOT_DIR:A}
    _parent_real=${_parent_root:A}
    _rel=${_zdot_real#${_parent_real}/}

    # Read remote + branch from zstyle (space-separated value)
    zstyle -s ':zdot:update' subtree-remote _subtree_spec || {
        zdot_warn "zdot: subtree-remote zstyle not set"
        return 1
    }
    _remote=${_subtree_spec%% *}
    _branch=${_subtree_spec#* }
    [[ -z "$_remote" || -z "$_branch" ]] && {
        zdot_warn "zdot: subtree-remote must be 'remote branch' (space-separated)"
        return 1
    }

    # Snapshot pre-pull HEAD of the zdot subtree
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1

    # Subtree pull (squash to keep parent history clean)
    git -C "$_parent_real" subtree pull --prefix="$_rel" "$_remote" "$_branch" --squash || {
        zdot_warn "zdot: subtree pull failed"
        return 1
    }

    # Record the remote SHA we just pulled so future
    # _update_core_is_available_subtree can compare against it.
    local _remote_url _pulled_sha
    _remote_url=$(git -C "$ZDOT_DIR" config "remote.${_remote}.url" 2>/dev/null)
    _pulled_sha=$(_update_core_resolve_remote_sha "$_remote_url" "$_branch" 2>/dev/null)
    if [[ -n "$_pulled_sha" ]]; then
        _update_core_write_sha_marker "$ZDOT_DIR" "$_pulled_sha"
    fi

    # Snapshot post-pull HEAD
    _new=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    _zdot_update_apply "$_old" "$_new"
    local _itc_mode; zstyle -s ':zdot:update' in-tree-commit _itc_mode

    # Stage the SHA marker alongside the subtree when committing
    # to the parent repo.
    _update_core_sha_marker_path "$ZDOT_DIR"
    local _marker_path=$REPLY
    if [[ "$_itc_mode" != "none" && -f "$_marker_path" ]]; then
        git -C "$_parent_real" add "$_marker_path" 2>/dev/null
    fi

    _update_core_commit_parent "$_parent_real" "$_rel" "subtree updated" "zdot: update subtree ${_rel}" "$_itc_mode"
}

# ---------------------------------------------------------------------------
# Top-level orchestration
# ---------------------------------------------------------------------------

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

    # 5. Check for update
    # Detect topology early so subtree deployments use the marker-based check
    local _subtree_spec
    zstyle -s ':zdot:update' subtree-remote _subtree_spec
    _update_core_detect_deployment "$ZDOT_DIR" "$_subtree_spec"   # sets REPLY
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
        # 2 = error fetching; 1 = up to date — either way, write timestamp and exit
        _update_core_write_timestamp "$_ts" $(( _avail == 2 ? _avail : 0 )) ""
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 6. Subdir mode — zdot is a plain tracked subdir of a parent repo
    #     (e.g. dotfiler); updates are the parent repo's responsibility.
    if [[ "$_deploy" == subdir ]]; then
        zdot_info "zdot: update available but zdot is a tracked subdir of a parent repo."
        zdot_info "zdot: the parent repo manages updates; consider:"
        zdot_info "zdot:   zstyle ':zdot:update' mode disabled"
        _update_core_write_timestamp "$_ts" 0 ""
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 7. Dispatch by mode
    local _pull_fn
    case $_deploy in
        submodule)  _pull_fn=_zdot_update_submodule_apply ;;
        subtree)    _pull_fn=_zdot_update_subtree_apply   ;;
        *)          _pull_fn=_zdot_update_standalone_apply ;;
    esac

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
            # Only prompt if we have a real TTY and no buffered input already
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
# Cleanup: unset all private functions after the hook is wired
# ---------------------------------------------------------------------------

_zdot_update_cleanup() {
    unset -f \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_apply \
        _zdot_update_standalone_apply \
        _zdot_update_submodule_apply \
        _zdot_update_subtree_apply \
        warn info error verbose \
        2>/dev/null
    # Clean up update_core.sh shared primitives (no-op if update_core.sh was not sourced)
    { command -v _update_core_cleanup &>/dev/null && _update_core_cleanup; } 2>/dev/null || true
    # Note: _zdot_update_handle_update itself is kept alive — it is the hook body.
    # _zdot_update_cleanup is called once from the bottom of this file; self-unset last.
    unset -f _zdot_update_cleanup 2>/dev/null
}

# ---------------------------------------------------------------------------
# Wire into zdot hook system and clean up private helpers
# ---------------------------------------------------------------------------
# The hook runs after all other hooks complete (--group finally), so secrets
# and plugins are fully loaded before any prompt/pull occurs.

zdot_register_hook _zdot_update_handle_update \
    --name zdot-update \
    --context interactive \
    --group finally

# Clean up all helper functions — _zdot_update_handle_update captures everything
# it needs via closures over the zstyle/git calls at invocation time.
_zdot_update_cleanup

