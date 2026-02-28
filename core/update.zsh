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
#   zstyle ':zdot:update' submodule-pointer   none       # none|prompt|auto
#   zstyle ':zdot:dotfiler' scripts-dir       ""         # auto-detected if empty
#
# Deployment scenarios:
#   standalone   — ZDOT_DIR is its own git root; zdot does git pull + apply
#   submodule    — ZDOT_DIR is a registered submodule inside a parent repo;
#                  zdot does git submodule update --remote + apply + pointer handling
#   subdir       — ZDOT_DIR is inside a parent repo but not a submodule;
#                  treated like standalone (pull from zdot's own origin remote)
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

    zsh -f "$_scripts_dir/update.sh" \
        --repo-dir "$ZDOT_DIR" \
        --link-dest "$_destdir" \
        --range "${_old}..${_new}"
}

# ---------------------------------------------------------------------------
# Submodule pointer handling
# ---------------------------------------------------------------------------

_zdot_update_handle_submodule_ptr() {
    local _parent=$1 _rel=$2 _new=$3
    local _ptr_mode
    zstyle -s ':zdot:update' submodule-pointer _ptr_mode
    case ${_ptr_mode:-none} in
        auto)
            git -C "$_parent" add "$_rel" \
                && git -C "$_parent" commit -m "zdot: update submodule to ${_new[1,12]}"
            ;;
        prompt)
            # Only prompt if there is no buffered user input already
            _zdot_update_has_typed_input && return 0
            print -n "zdot: commit updated submodule pointer in parent repo? [y/N] "
            local _ans
            read -r -k1 _ans; print ""
            if [[ "$_ans" == (y|Y) ]]; then
                git -C "$_parent" add "$_rel" \
                    && git -C "$_parent" commit -m "zdot: update submodule to ${_new[1,12]}"
            fi
            ;;
        none|*)
            zdot_info "zdot: submodule pointer updated — parent repo is dirty (commit manually)"
            ;;
    esac
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
    _remote=$(_zdot_update_get_default_remote)
    _branch=$(_zdot_update_get_default_branch "$_remote")
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
    _remote=$(_zdot_update_get_default_remote)
    _branch=$(_zdot_update_get_default_branch "$_remote")
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 1
    [[ "$_old" == "$_new" ]] && return 0

    git -C "$_parent_real" submodule update --remote -- "$_rel" || {
        zdot_warn "zdot: submodule update failed"
        return 1
    }

    _zdot_update_apply "$_old" "$_new"
    _zdot_update_handle_submodule_ptr "$_parent_real" "$_rel" "$_new"
}

# ---------------------------------------------------------------------------
# Stdin guard (do not prompt if user has already typed input)
# ---------------------------------------------------------------------------

_zdot_update_has_typed_input() {
    # Returns 0 if stdin has buffered input (do not prompt), 1 if stdin is clear
    zmodload zsh/zselect 2>/dev/null || return 1
    local _old_settings
    _old_settings=$(stty -g 2>/dev/null)
    stty -icanon min 0 time 0 2>/dev/null
    local _result=1
    zselect -t 0 -r 0 2>/dev/null && _result=0
    stty "$_old_settings" 2>/dev/null
    return $_result
}



_zdot_update_current_epoch() {
    zmodload zsh/datetime 2>/dev/null
    print -n $EPOCHSECONDS
}

_zdot_update_get_default_remote() {
    # Get the remote that the current branch tracks, fallback to 'origin'
    local current_branch upstream
    current_branch=$(git -C "$ZDOT_DIR" branch --show-current 2>/dev/null)
    if [[ -n "$current_branch" ]]; then
        upstream=$(git -C "$ZDOT_DIR" config --get "branch.${current_branch}.remote" 2>/dev/null)
    fi
    # Fallback to first remote, typically 'origin'
    if [[ -z "$upstream" ]]; then
        upstream=$(git -C "$ZDOT_DIR" remote 2>/dev/null | head -n1)
    fi
    print -n "${upstream:-origin}"
}

_zdot_update_get_default_branch() {
    local remote="${1:-origin}" default_branch line
    # Try to get the default branch from remote HEAD
    default_branch=$(git -C "$ZDOT_DIR" symbolic-ref \
        "refs/remotes/${remote}/HEAD" 2>/dev/null)
    default_branch=${default_branch#refs/remotes/${remote}/}
    # If that fails, try to get it from remote show
    if [[ -z "$default_branch" ]]; then
        local remote_output
        remote_output=$(git -C "$ZDOT_DIR" remote show "$remote" 2>/dev/null)
        for line in ${(f)remote_output}; do
            if [[ "$line" == *"HEAD branch:"* ]]; then
                default_branch="${${line#*: }// /}"
                break
            fi
        done
    fi
    # Final fallback to common default branches
    if [[ -z "$default_branch" ]]; then
        for branch in main master; do
            git -C "$ZDOT_DIR" show-ref --verify --quiet \
                "refs/remotes/${remote}/${branch}" 2>/dev/null && {
                default_branch=$branch; break
            }
        done
    fi
    print -n "${default_branch:-main}"
}

# ---------------------------------------------------------------------------
# Lock management
# ---------------------------------------------------------------------------

_zdot_update_lock_dir() {
    print -n "${XDG_CACHE_HOME:-$HOME/.cache}/zdot/update.lock"
}

_zdot_update_acquire_lock() {
    local _lock
    _lock=$(_zdot_update_lock_dir)
    mkdir -p "${_lock:h}" 2>/dev/null
    if ! mkdir "$_lock" 2>/dev/null; then
        # Stale lock: remove if older than 24h
        zmodload zsh/stat 2>/dev/null
        local _mtime
        _mtime=$(zstat +mtime "$_lock" 2>/dev/null) || _mtime=0
        local _now
        _now=$(_zdot_update_current_epoch)
        if (( _now - _mtime > 86400 )); then
            rm -rf "$_lock" && mkdir "$_lock" 2>/dev/null || return 1
        else
            return 1
        fi
    fi
    return 0
}

_zdot_update_release_lock() {
    rmdir "$(_zdot_update_lock_dir)" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Update availability check
# ---------------------------------------------------------------------------

_zdot_update_is_available() {
    # Returns 0 if an update is available, 1 if up to date, 2 on error
    local _remote _branch _local_sha _remote_sha
    _remote=$(_zdot_update_get_default_remote)
    _branch=$(_zdot_update_get_default_branch "$_remote")
    git -C "$ZDOT_DIR" fetch "$_remote" "$_branch" --quiet 2>/dev/null || return 2
    _local_sha=$(git -C "$ZDOT_DIR" rev-parse HEAD 2>/dev/null) || return 2
    _remote_sha=$(git -C "$ZDOT_DIR" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 2
    [[ "$_local_sha" != "$_remote_sha" ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# dotfiler scripts detection (3-step priority)
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
    if [[ -n "$_root" && -f "$_root/scripts/setup.sh" && -f "$_root/scripts/update.sh" ]]; then
        REPLY="$_root/scripts"; return 0
    fi

    # 3. Plugin cache path — clone on demand if not yet present.
    # zdot_use_bundle already registered this repo at source time (for opted-in users)
    # so the clone will not be treated as an orphan by zdot_clean_plugins.
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="$_cache/georgeharker/dotfiler/scripts"
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
    _zdot_update_acquire_lock || return 0

    # 4. Frequency check
    local _ts _freq _now _last_epoch=0
    _ts=$(_zdot_update_ts_file)
    [[ -f "$_ts" ]] && { local LAST_EPOCH=0; source "$_ts" 2>/dev/null; _last_epoch=$LAST_EPOCH; }
    zstyle -s ':zdot:update' frequency _freq; : ${_freq:=3600}
    _now=$(_zdot_update_current_epoch)
    if (( _now - _last_epoch < _freq )); then
        _zdot_update_release_lock
        return 0
    fi

    # 5. Check for update
    _zdot_update_is_available
    local _avail=$?
    if (( _avail != 0 )); then
        # 2 = error fetching; 1 = up to date — either way, write timestamp and exit
        _zdot_update_write_timestamp $(( _avail == 2 ? _avail : 0 )) ""
        _zdot_update_release_lock
        return 0
    fi

    # 6. Detect deployment topology
    _zdot_update_detect_deployment   # sets REPLY
    local _deploy=$REPLY

    # 6a. Subdir mode — zdot is a plain tracked subdir of a parent repo
    #     (e.g. dotfiler); updates are the parent repo's responsibility.
    if [[ "$_deploy" == subdir ]]; then
        zdot_info "zdot: update available but zdot is a tracked subdir of a parent repo."
        zdot_info "zdot: the parent repo manages updates; consider:"
        zdot_info "zdot:   zstyle ':zdot:update' mode disabled"
        _zdot_update_write_timestamp 0 ""
        _zdot_update_release_lock
        return 0
    fi

    # 7. Dispatch by mode
    local _pull_fn
    [[ "$_deploy" == submodule ]] \
        && _pull_fn=_zdot_update_submodule_apply \
        || _pull_fn=_zdot_update_standalone_apply

    case $_mode in
        reminder)
            zdot_info "zdot: update available (run: git -C \$ZDOT_DIR pull)"
            _zdot_update_write_timestamp 0 ""
            ;;
        auto)
            $_pull_fn
            _zdot_update_write_timestamp $? ""
            ;;
        prompt)
            # Only prompt if we have a real TTY and no buffered input already
            if [[ -t 1 ]] && ! _zdot_update_has_typed_input; then
                print -n "zdot: update available. Pull now? [Y/n] "
                local _ans
                read -r -k1 _ans; print ""
                if [[ "$_ans" != (n|N) ]]; then
                    $_pull_fn
                    _zdot_update_write_timestamp $? ""
                fi
            fi
            ;;
    esac

    _zdot_update_release_lock
}

# ---------------------------------------------------------------------------
# Deployment detection
# ---------------------------------------------------------------------------

_zdot_update_detect_deployment() {
    # Sets REPLY to: standalone | submodule | subdir | none
    local _zdot_root _zdot_real _parent_real _rel
    _zdot_root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null) || {
        REPLY=none; return 0
    }
    _zdot_real=${ZDOT_DIR:A}
    _parent_real=${_zdot_root:A}

    if [[ "$_zdot_real" == "$_parent_real" ]]; then
        REPLY=standalone; return 0
    fi

    # zdot is inside a parent repo — submodule or plain subdir?
    _rel=${_zdot_real#${_parent_real}/}
    if git -C "$_parent_real" submodule status -- "$_rel" &>/dev/null; then
        REPLY=submodule; return 0
    fi

    # Plain tracked subdir — parent repo manages updates
    REPLY=subdir; return 0
}

_zdot_update_ts_file() {
    print -n "${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zdot_update"
}

_zdot_update_write_timestamp() {
    local _exit_status="${1:-0}" _error="${2:-}"
    local _ts
    _ts=$(_zdot_update_ts_file)
    mkdir -p "${_ts:h}" 2>/dev/null
    {
        print "LAST_EPOCH=$(_zdot_update_current_epoch)"
        (( _exit_status != 0 )) && print "EXIT_STATUS=$_exit_status"
        [[ -n "$_error" ]] && print "ERROR=$_error"
    } >| "$_ts"
}

# ---------------------------------------------------------------------------
# Cleanup: unset all private functions after the hook is wired
# ---------------------------------------------------------------------------

_zdot_update_cleanup() {
    unset -f \
        _zdot_update_current_epoch \
        _zdot_update_get_default_remote \
        _zdot_update_get_default_branch \
        _zdot_update_lock_dir \
        _zdot_update_acquire_lock \
        _zdot_update_release_lock \
        _zdot_update_ts_file \
        _zdot_update_write_timestamp \
        _zdot_update_is_available \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_detect_deployment \
        _zdot_update_apply \
        _zdot_update_handle_submodule_ptr \
        _zdot_update_standalone_apply \
        _zdot_update_submodule_apply \
        _zdot_update_has_typed_input \
        2>/dev/null
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

