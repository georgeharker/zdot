# core/update-impl.zsh
# zdot update implementation — pure functions, no side effects at source time.
#
# Callers must:
#   1. Set ZDOT_DIR (linktree path) and ZDOT_REPO (real repo path) before sourcing this file.
#   2. Set _zdot_dotfiler_scripts_dir to the dotfiler scripts path.
#   3. Source update_core.sh before sourcing this file (provides _update_core_*).
#   4. Define warn / info / error / verbose shims (only called at runtime).
#
# Public entry points:
#   _zdot_update_find_dotfiler_scripts   → REPLY = scripts dir; rc 0/1
#   _zdot_update_hook_check              → 0=available, 1=up-to-date, 2=error
#   _zdot_update_hook_plan               → populate _dotfiler_plan_zdot_* in-process
#                                          returns 0=populated, 0=nothing-to-do
#                                          (check _dotfiler_plan_zdot_range for empty)
#   _zdot_update_hook_pull               → git operations only (no setup.sh)
#   _zdot_update_hook_unpack             → setup.sh operations (post all-pulls)
#   _zdot_update_hook_post               → commit parents, SHA markers
#   _zdot_update_hook_register           → SOURCE mode entry: check availability
#   _zdot_update_handle_update           → shell-hook orchestrator (standalone zdot)
#
# Internal shared primitive:
#   _zdot_update_apply_range <old> <new> → build file lists then call setup.sh

# ---------------------------------------------------------------------------
# dotfiler scripts detection (3-step priority)
# ---------------------------------------------------------------------------
# Sets REPLY to the dotfiler scripts directory; returns 0/1.

_zdot_update_find_dotfiler_scripts() {
    local _candidate

    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate
    if [[ -n "$_candidate" && -f "$_candidate/setup.sh" \
                           && -f "$_candidate/update.sh" ]]; then
        REPLY=$_candidate; return 0
    fi

    # 2. Inside a parent repo that already has dotfiler scripts
    local _root
    _update_core_get_parent_root "$ZDOT_REPO"; _root=${reply[1]}
    if [[ -n "$_root" && -f "$_root/.nounpack/dotfiler/setup.sh" \
                       && -f "$_root/.nounpack/dotfiler/update.sh" ]]; then
        REPLY="$_root/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache — clone on demand if not yet present
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="$_cache/georgeharker/dotfiler"
    if [[ ! -f "$_candidate/setup.sh" || ! -f "$_candidate/update.sh" ]]; then
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
# Hook phase functions (_zdot_update_hook_*)
# ---------------------------------------------------------------------------
# These are the phase primitives shared between:
#   - dotfiler orchestrator (SOURCE mode: all fns defined in-process)
#   - zdot standalone orchestrator (_zdot_update_handle_update)

# check: is an update available?
# Returns 0=available, 1=up-to-date, 2=error.
_zdot_update_hook_check() {
    _update_core_is_available "$ZDOT_REPO" "" 1
    return $?
}

# plan: populate _dotfiler_plan_zdot_* directly in the caller's process.
# Called pre-pull. Does NOT modify any git state.
# Returns 0 always. "Nothing to do" = _dotfiler_plan_zdot_range is empty/unset.
# Caller must pre-declare: typeset -gaU _dotfiler_plan_zdot_to_unpack
#                                        _dotfiler_plan_zdot_to_remove
_zdot_update_hook_plan() {
    local _subtree_spec
    zstyle -s ':zdot:update' subtree-remote _subtree_spec 2>/dev/null \
        || _subtree_spec=""

    _update_core_detect_deployment "$ZDOT_REPO" "$_subtree_spec"
    local _topology="$REPLY"

    # Resolve old/new SHAs — use hint range from dotfiler if provided
    # (set when update.sh is run with --range or --commit-hash and was able
    # to resolve the zdot component range from the dotfiles range via markers).
    local _old _new _remote _branch
    _old=$(git -C "$ZDOT_REPO" rev-parse HEAD 2>/dev/null) || return 0

    if [[ -n "${_dotfiler_hint_range_zdot:-}" ]]; then
        # Hint range: "old_comp_sha..new_comp_sha" resolved by dotfiler
        _old="${_dotfiler_hint_range_zdot%%..*}"
        _new="${_dotfiler_hint_range_zdot#*..}"
        verbose "zdot hook plan: using hint range ${_dotfiler_hint_range_zdot}"
        # Still need remote/branch for pull phase
        _remote=$(_update_core_get_default_remote "$ZDOT_REPO")
        _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
    else
        case "$_topology" in
            subtree)
                _remote="${_subtree_spec%% *}"
                _branch="${_subtree_spec#* }"
                [[ "$_branch" == "$_remote" ]] && _branch=""
                [[ -z "$_branch" ]] && \
                    _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
                local _remote_url
                _remote_url=$(git -C "$ZDOT_REPO" \
                    config "remote.${_remote}.url" 2>/dev/null) || return 0
                _update_core_resolve_remote_sha "$_remote_url" "$_branch"
                _new="$REPLY"
                ;;
            submodule|standalone|*)
                _remote=$(_update_core_get_default_remote "$ZDOT_REPO")
                _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
                git -C "$ZDOT_REPO" fetch -q "$_remote" "$_branch" 2>/dev/null
                _new=$(git -C "$ZDOT_REPO" \
                    rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 0
                ;;
        esac
    fi

    # Nothing to do — leave _dotfiler_plan_zdot_range unset
    [[ "$_old" == "$_new" ]] && return 0

    verbose "zdot hook plan: topology=${_topology} old=${_old[1,12]} new=${_new[1,12]}"

    local _link_dest
    zstyle -s ':zdot:update' destdir _link_dest \
        || _link_dest="${XDG_CONFIG_HOME:-$HOME/.config}/zdot"

    # Build file lists using the shared update_core helper
    typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
    _update_core_build_file_lists "$ZDOT_REPO" "${_old}..${_new}"

    verbose "zdot hook plan: ${#_update_core_files_to_unpack[@]} to unpack, \
${#_update_core_files_to_remove[@]} to remove"

    # Direct assignment into caller's scope — no print, no eval needed.
    # Phase functions are registered via _update_register_hook (dotfiler path)
    # or called directly (_zdot_update_handle_update standalone path).
    # to_unpack/to_remove are additive (typeset -gaU ensures uniqueness).
    typeset -gaU _dotfiler_plan_zdot_to_unpack _dotfiler_plan_zdot_to_remove
    _dotfiler_plan_zdot_repo_dir="$ZDOT_REPO"
    _dotfiler_plan_zdot_link_dest="$_link_dest"
    _dotfiler_plan_zdot_topology="$_topology"
    _dotfiler_plan_zdot_range="${_old}..${_new}"
    _dotfiler_plan_zdot_remote="$_remote"
    _dotfiler_plan_zdot_branch="$_branch"
    _dotfiler_plan_zdot_subtree_spec="$_subtree_spec"
    _dotfiler_plan_zdot_to_unpack+=("${_update_core_files_to_unpack[@]}")
    _dotfiler_plan_zdot_to_remove+=("${_update_core_files_to_remove[@]}")
    return 0
}

# pull: git operations only — no setup.sh, no new zsh processes.
# Reads topology and remote/branch from _dotfiler_plan_zdot_* vars set by plan.
_zdot_update_hook_pull() {
    local _topology="${_dotfiler_plan_zdot_topology:-}"
    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _remote="${_dotfiler_plan_zdot_remote:-}"
    local _branch="${_dotfiler_plan_zdot_branch:-}"

    case "$_topology" in
        standalone|'')
            git -C "$_repo_dir" pull -q "$_remote" "$_branch" || {
                warn "zdot: pull failed"; return 1
            }
            ;;
        submodule)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            git -C "$_parent" submodule update --remote -- "$_rel" || {
                warn "zdot: submodule update failed"; return 1
            }
            ;;
        subtree)
            local _parent
            _parent=$(git -C "$_repo_dir" \
                rev-parse --show-toplevel 2>/dev/null) || return 1
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            git -C "$_parent" subtree pull \
                --prefix="$_rel" "$_remote" "$_branch" --squash || {
                warn "zdot: subtree pull failed"; return 1
            }
            ;;
        subdir)
            verbose "zdot: subdir topology — parent repo manages updates"
            return 0
            ;;
        *)
            warn "zdot: unhandled topology '${_topology}' in pull"
            return 1
            ;;
    esac
    return 0
}

# unpack: setup.sh for zdot files — called after ALL pulls complete.
# By this point every repo is at new HEAD.
_zdot_update_hook_unpack() {
    local _link_tree
    zstyle -s ':zdot:update' link-tree _link_tree || _link_tree=true
    [[ "$_link_tree" == false ]] && return 0

    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _link_dest="${_dotfiler_plan_zdot_link_dest}"
    local -a _to_unpack=("${_dotfiler_plan_zdot_to_unpack[@]}")
    local -a _to_remove=("${_dotfiler_plan_zdot_to_remove[@]}")

    # Remove deleted symlinks
    local _f _dest
    for _f in "${_to_remove[@]}"; do
        _dest="${_link_dest}/${_f}"
        if [[ -L "$_dest" ]]; then
            verbose "zdot: removing symlink ${_dest}"
            rm -f "$_dest"
        fi
    done

    [[ ${#_to_unpack[@]} -eq 0 ]] && return 0

    # setup.sh subprocess — all repos at new HEAD at this point
    "${_zdot_dotfiler_scripts_dir}/setup.sh" \
        --repo-dir "$_repo_dir" \
        --link-dest "$_link_dest" \
        -u \
        "${_to_unpack[@]}"
    return $?
}

# post: commit parent pointer, write SHA marker if subtree.
_zdot_update_hook_post() {
    local _topology="${_dotfiler_plan_zdot_topology:-}"
    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _itc_mode
    zstyle -s ':zdot:update' in-tree-commit _itc_mode

    case "$_topology" in
        submodule)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            local _new="${_dotfiler_plan_zdot_range#*..}"
            _update_core_commit_parent "$_parent" "$_rel" \
                "submodule pointer updated" \
                "zdot: update submodule to ${_new[1,12]}" \
                "$_itc_mode"
            ;;
        subtree)
            local _parent
            _parent=$(git -C "$_repo_dir" \
                rev-parse --show-toplevel 2>/dev/null) || return 1
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            local _remote="${_dotfiler_plan_zdot_remote}"
            local _branch="${_dotfiler_plan_zdot_branch}"
            local _remote_url _pulled_sha
            _remote_url=$(git -C "$_repo_dir" \
                config "remote.${_remote}.url" 2>/dev/null)
            _pulled_sha=$(_update_core_resolve_remote_sha \
                "$_remote_url" "$_branch" 2>/dev/null)
            [[ -n "$_pulled_sha" ]] && \
                _update_core_write_sha_marker "$_repo_dir" "$_pulled_sha"
            _update_core_sha_marker_path "$_repo_dir"
            local _marker_path="$REPLY"
            if [[ "$_itc_mode" != none && -f "$_marker_path" ]]; then
                git -C "$_parent" add "$_marker_path" 2>/dev/null
            fi
            _update_core_commit_parent "$_parent" "$_rel" \
                "subtree updated" "zdot: update subtree ${_rel}" "$_itc_mode"
            ;;
        standalone)
            # Write ext SHA marker adjacent to zdot dir — tracked in the
            # dotfiles repo so any dotfiles range can resolve the zdot range.
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _remote_url _pulled_sha
            _remote_url=$(git -C "$_repo_dir" \
                config "remote.${_dotfiler_plan_zdot_remote}.url" 2>/dev/null)
            _pulled_sha=$(_update_core_resolve_remote_sha \
                "$_remote_url" "$_dotfiler_plan_zdot_branch" 2>/dev/null)
            if [[ -n "$_pulled_sha" ]]; then
                _update_core_write_ext_marker "$_repo_dir" "$_pulled_sha"
                _update_core_ext_marker_path "$_repo_dir"
                local _marker_path="$REPLY"
                if [[ "$_itc_mode" != none \
                    && -f "$_marker_path" \
                    && -n "$_parent" ]]; then
                    git -C "$_parent" add "$_marker_path" 2>/dev/null
                    _update_core_commit_parent "$_parent" \
                        "${${_marker_path:A}#${_parent:A}/}" \
                        "ext sha marker updated" \
                        "zdot: record standalone SHA ${_pulled_sha[1,12]}" \
                        "$_itc_mode"
                fi
            fi
            ;;
        subdir)
            # subdir: component is part of dotfiles tree — parent manages versioning
            verbose "zdot: post: subdir topology — parent repo tracks versioning"
            ;;
        *)
            verbose "zdot: post: unknown topology '${_topology}' — nothing to do"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Internal shared primitive: apply_range
# ---------------------------------------------------------------------------
# Build file lists for old..new then call setup.sh in-process.
# Used by the apply-update backward-compat verb and directly if needed.

_zdot_update_apply_range() {
    local _old=$1 _new=$2

    local _link_tree
    zstyle -s ':zdot:update' link-tree _link_tree || _link_tree=true
    [[ "$_link_tree" == false ]] && return 0

    local _destdir
    zstyle -s ':zdot:update' destdir _destdir
    : ${_destdir:=${XDG_CONFIG_HOME:-$HOME/.config}/zdot}

    typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
    _update_core_build_file_lists "$ZDOT_REPO" "${_old}..${_new}"

    local _f _dest
    for _f in "${_update_core_files_to_remove[@]}"; do
        _dest="${_destdir}/${_f}"
        [[ -L "$_dest" ]] && rm -f "$_dest"
    done

    [[ ${#_update_core_files_to_unpack[@]} -eq 0 ]] && return 0

    "${_zdot_dotfiler_scripts_dir}/setup.sh" \
        --repo-dir "$ZDOT_REPO" \
        --link-dest "$_destdir" \
        -u \
        "${_update_core_files_to_unpack[@]}"
    return $?
}

# _zdot_update_hook_register
# Called when dotfiler sources this hook.
# Detects topology at registration time (cheap, no network) and passes
# component_dir + topology to _update_register_hook so dotfiler can resolve
# component ranges from a dotfiles range without calling plan_fn first.

_zdot_update_hook_register() {
    local _subtree_spec
    zstyle -s ':zdot:update' subtree-remote _subtree_spec 2>/dev/null \
        || _subtree_spec=""
    _update_core_detect_deployment "$ZDOT_REPO" "$_subtree_spec"
    local _topology="$REPLY"
    _update_register_hook zdot \
        _zdot_update_hook_check \
        _zdot_update_hook_plan \
        _zdot_update_hook_pull \
        _zdot_update_hook_unpack \
        _zdot_update_hook_post \
        _zdot_update_impl_cleanup_hook \
        "$ZDOT_REPO" \
        "$_topology"
}


# ---------------------------------------------------------------------------
# Shell-hook orchestrator (_zdot_update_handle_update)
# ---------------------------------------------------------------------------
# Called by the zdot hook system at shell startup (interactive shells only),
# WITHOUT dotfiler being involved. Uses the same _zdot_update_hook_*
# primitives as the dotfiler SOURCE-mode path — the only difference is that
# this function owns the lock, stamp, frequency check, and mode dispatch.

_zdot_update_handle_update() {
    # 1. Read mode; exit immediately if disabled (default)
    local _mode
    zstyle -s ':zdot:update' mode _mode
    [[ "${_mode:-disabled}" == disabled ]] && return 0

    # 2. Early-exit guards
    [[ -n "$ZDOT_REPO" && -d "$ZDOT_REPO" ]] || return 0
    command -v git &>/dev/null || return 0
    git -C "$ZDOT_REPO" rev-parse --is-inside-work-tree &>/dev/null || return 0

    # 3. Acquire lock (prevents concurrent shells racing)
    local _lock_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/update.lock"
    _update_core_acquire_lock "$_lock_dir" || return 0

    # 4. Frequency check
    local _ts _freq
    _ts="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zdot_update"
    zstyle -s ':zdot:update' frequency _freq; : ${_freq:=3600}
    _update_core_should_update "$_ts" "$_freq" false || {
        _update_core_release_lock "$_lock_dir"
        return 0
    }

    # 5. Check availability
    _zdot_update_hook_check || {
        _update_core_write_timestamp "$_ts"
        _update_core_release_lock "$_lock_dir"
        return 0
    }

    # 6. Dispatch by mode
    case "$_mode" in
        reminder)
            zdot_info "zdot: update available (run: git -C \$ZDOT_REPO pull)"
            _update_core_write_timestamp "$_ts" 0 ""
            _update_core_release_lock "$_lock_dir"
            return 0
            ;;
        prompt)
            if ! { [[ -t 1 ]] && ! _update_core_has_typed_input; }; then
                _update_core_release_lock "$_lock_dir"
                return 0
            fi
            print -n "zdot: update available. Pull now? [Y/n] "
            local _ans
            read -r -k1 _ans; print ""
            if [[ "$_ans" == (n|N) ]]; then
                _update_core_release_lock "$_lock_dir"
                return 0
            fi
            ;;
        auto) ;;   # fall through to update
        *)
            _update_core_release_lock "$_lock_dir"
            return 0
            ;;
    esac

    # 7. Plan (pre-pull, in-process — direct assignment, no subprocess, no zshenv)
    typeset -gaU _dotfiler_plan_zdot_to_unpack _dotfiler_plan_zdot_to_remove
    _dotfiler_plan_zdot_range=""
    _zdot_update_hook_plan || {
        warn "zdot: plan failed"
        _update_core_write_timestamp "$_ts" 1 "Plan failed"
        _update_core_release_lock "$_lock_dir"
        return 1
    }
    if [[ -z "${_dotfiler_plan_zdot_range:-}" ]]; then
        # Nothing to do (old==new)
        _update_core_write_timestamp "$_ts"
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 8. Subdir mode — parent repo manages updates
    if [[ "${_dotfiler_plan_zdot_topology:-}" == subdir ]]; then
        zdot_info "zdot: update available but zdot is a tracked subdir."
        zdot_info "zdot: the parent repo manages updates."
        _update_core_write_timestamp "$_ts" 0 ""
        _update_core_release_lock "$_lock_dir"
        return 0
    fi

    # 9. Pull — git only, no zsh subprocesses
    _zdot_update_hook_pull || {
        warn "zdot: pull failed"
        _update_core_write_timestamp "$_ts" 1 "Pull failed"
        _update_core_release_lock "$_lock_dir"
        return 1
    }

    # 10. Unpack — setup.sh subprocess; all repos at new HEAD
    _zdot_update_hook_unpack || {
        warn "zdot: unpack failed"
        _update_core_write_timestamp "$_ts" 1 "Unpack failed"
        _update_core_release_lock "$_lock_dir"
        return 1
    }

    # 11. Post — commit parents, SHA markers etc.
    _zdot_update_hook_post || {
        warn "zdot: post-update steps failed (non-fatal)"
    }

    _update_core_write_timestamp "$_ts" 0 "Update successful"
    _update_core_release_lock "$_lock_dir"
    return 0
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# TWO cleanup modes:
#
# _zdot_update_impl_cleanup_hook
#   Called by dotfiler-hook.zsh after check mode or source mode completes.
#   Unsets everything — hook has finished its work.
#
# _zdot_update_impl_cleanup_shell
#   Called by update.zsh after zdot_register_hook.
#   Keeps all functions that _zdot_update_handle_update calls at runtime:
#     _zdot_update_hook_{check,plan,pull,unpack,post}
#     _zdot_update_apply_range (called internally by pull/unpack/post)
#   Unsets bootstrap / registration helpers not needed at runtime.

_zdot_update_impl_cleanup_hook() {
    unset -f \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_hook_check \
        _zdot_update_hook_plan \
        _zdot_update_hook_pull \
        _zdot_update_hook_unpack \
        _zdot_update_hook_post \
        _zdot_update_apply_range \
        _zdot_update_hook_register \
        _zdot_update_handle_update \
        _zdot_update_impl_cleanup_shell \
        _zdot_update_impl_cleanup_hook \
        2>/dev/null
    return 0
}

_zdot_update_impl_cleanup_shell() {
    # Unset helpers not needed after shell startup — keep runtime fns alive.
    unset -f \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_hook_register \
        _zdot_update_impl_cleanup_hook \
        _zdot_update_impl_cleanup_shell \
        2>/dev/null
    # _zdot_update_hook_{check,plan,pull,unpack,post} — kept (called by _zdot_update_handle_update)
    # _zdot_update_apply_range — kept (used internally by pull/unpack/post primitives)
    # _zdot_update_handle_update — kept (IS the hook body)
    return 0
}
