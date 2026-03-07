# core/update-impl.zsh
# zdot update implementation — pure functions, no side effects at source time.
#
# Callers must:
#   1. Set ZDOT_DIR (linktree path) and ZDOT_REPO (real repo path) before sourcing this file.
#   2. Set _zdot_dotfiler_scripts_dir to the dotfiler scripts path.
#   3. Source update_core.zsh before sourcing this file (provides _update_core_*).
#   4. Define zdot_warn / zdot_info / zdot_error / zdot_verbose shims (only called at runtime).
#
# Public entry points:
#   _zdot_update_find_dotfiler_scripts   → REPLY = scripts dir; rc 0/1
#   _zdot_update_hook_check              → 0=available, 1=up-to-date, 2=zdot_error
#   _zdot_update_hook_plan               → populate _dotfiler_plan_zdot_* in-process
#                                          returns 0=populated, 0=nothing-to-do
#                                          (check _dotfiler_plan_zdot_range for empty)
#   _zdot_update_hook_pull               → git operations only (no setup.zsh)
#   _zdot_update_hook_unpack             → setup.zsh operations (post all-pulls)
#   _zdot_update_hook_post               → commit parents, SHA markers
#   _zdot_update_hook_register           → SOURCE mode entry: check availability
#   _zdot_update_handle_update           → shell-hook orchestrator (standalone zdot)


# ---------------------------------------------------------------------------
# dotfiler scripts detection (3-step priority)
# ---------------------------------------------------------------------------
# Sets REPLY to the dotfiler scripts directory; returns 0/1.

_zdot_update_find_dotfiler_scripts() {
    local _candidate

    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _candidate
    if [[ -n "$_candidate" && -f "$_candidate/setup.zsh" \
                           && -f "$_candidate/update.zsh" ]]; then
        REPLY=$_candidate; return 0
    fi

    # 2. Inside a parent repo that already has dotfiler scripts
    local _root
    _update_core_get_parent_root "$ZDOT_REPO"; _root=${reply[1]}
    if [[ -n "$_root" && -f "$_root/.nounpack/dotfiler/setup.zsh" \
                       && -f "$_root/.nounpack/dotfiler/update.zsh" ]]; then
        REPLY="$_root/.nounpack/dotfiler"; return 0
    fi

    # 3. Plugin cache — clone on demand if not yet present
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    _candidate="$_cache/georgeharker/dotfiler"
    if [[ ! -f "$_candidate/setup.zsh" || ! -f "$_candidate/update.zsh" ]]; then
        if (( ${+functions[zdot_plugin_clone]} )); then
            zdot_info "zdot: cloning dotfiler for update scripts..."
            zdot_plugin_clone "georgeharker/dotfiler" 2>/dev/null
        fi
    fi
    if [[ -f "$_candidate/setup.zsh" && -f "$_candidate/update.zsh" ]]; then
        REPLY=$_candidate; return 0
    fi

    REPLY=""; return 1
}

# Reads ':zdot:update' subtree-remote / subtree-url zstyles with sensible
# defaults. Sets _subtree_spec and _subtree_url in the caller's scope.
_zdot_update_init() {
    zstyle -s ':zdot:update' subtree-remote _subtree_spec 2>/dev/null \
        || _subtree_spec="zdot main"
    zstyle -s ':zdot:update' subtree-url _subtree_url 2>/dev/null \
        || _subtree_url="https://github.com/georgeharker/zdot.git"
}


# check: is an update available?
# Returns 0=available, 1=up-to-date, 2=zdot_error.
_zdot_update_hook_check() {
    local _subtree_spec _subtree_url
    _zdot_update_init

    _update_core_detect_deployment "$ZDOT_REPO" "$_subtree_spec"
    local _topology="$REPLY"

    if [[ "$_topology" == subtree ]]; then
        _update_core_is_available_subtree "$ZDOT_REPO" "$_subtree_spec" "$_subtree_url"
        return $?
    fi

    # standalone / submodule / subdir: compare zdot's own HEAD against remote.
    # allow_diverged=1: zdot_warn and proceed rather than treating diverged as zdot_error.
    _update_core_is_available "$ZDOT_REPO" "" 1
    return $?
}

# plan: populate _dotfiler_plan_zdot_* directly in the caller's process.
# Called pre-pull. Does NOT modify any git state.
# Returns 0 always. "Nothing to do" = _dotfiler_plan_zdot_range is empty/unset.
# Caller must pre-declare: typeset -gaU _dotfiler_plan_zdot_to_unpack
#                                        _dotfiler_plan_zdot_to_remove
_zdot_update_hook_plan() {
    local _subtree_spec _subtree_url
    _zdot_update_init

    _update_core_detect_deployment "$ZDOT_REPO" "$_subtree_spec"
    local _topology="$REPLY"

    # Resolve old/new SHAs — use hint range from dotfiler if provided
    # (set when update.zsh is run with --range or --commit-hash and was able
    # to resolve the zdot component range from the dotfiles range via markers).
    local _old _new _remote _branch
    _old=$(git -C "$ZDOT_REPO" rev-parse HEAD 2>/dev/null) || return 0

    if [[ -n "${_dotfiler_hint_range_zdot:-}" ]]; then
        # Hint range: "old_comp_sha..new_comp_sha" resolved by dotfiler
        _old="${_dotfiler_hint_range_zdot%%..*}"
        _new="${_dotfiler_hint_range_zdot#*..}"
        zdot_verbose "zdot hook plan: using hint range ${_dotfiler_hint_range_zdot}"
        # Still need remote/branch for pull phase
        _remote=$(_update_core_get_default_remote "$ZDOT_REPO")
        _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
    else
        case "$_topology" in
            subtree)
                local _remote_url
                _update_core_resolve_subtree_spec "$ZDOT_REPO" "$_subtree_spec" \
                    "$_subtree_url" || return 0
                _remote="${reply[1]}" _branch="${reply[2]}" _remote_url="${reply[3]}"
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

    # Always populate topology/remote/branch so pull knows what it's
    # dealing with.  An empty _dotfiler_plan_zdot_range signals "nothing
    # to do" — pull will skip the git operation but the type is known.
    local _link_dest
    zstyle -s ':zdot:update' destdir _link_dest \
        || _link_dest="${XDG_CONFIG_HOME:-$HOME/.config}/zdot"

    typeset -gaU _dotfiler_plan_zdot_to_unpack _dotfiler_plan_zdot_to_remove
    _dotfiler_plan_zdot_repo_dir="$ZDOT_REPO"
    _dotfiler_plan_zdot_link_dest="$_link_dest"
    _dotfiler_plan_zdot_topology="$_topology"
    _dotfiler_plan_zdot_remote="$_remote"
    _dotfiler_plan_zdot_branch="$_branch"
    _dotfiler_plan_zdot_subtree_spec="$_subtree_spec"
    _dotfiler_plan_zdot_subtree_url="$_subtree_url"

    # Nothing changed — topology is set but range stays empty.
    if [[ "$_old" == "$_new" ]]; then
        zdot_log_debug "zdot hook plan: topology=${_topology}, nothing to do (${_old[1,12]})"
        _dotfiler_plan_zdot_range=""
        return 0
    fi

    zdot_verbose "zdot hook plan: topology=${_topology} old=${_old[1,12]} new=${_new[1,12]}"

    # Build file lists using the shared update_core helper
    typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
    _update_core_build_file_lists "$ZDOT_REPO" "${_old}..${_new}"

    zdot_verbose "zdot hook plan: ${#_update_core_files_to_unpack[@]} to unpack, \
${#_update_core_files_to_remove[@]} to remove"

    _dotfiler_plan_zdot_range="${_old}..${_new}"
    _dotfiler_plan_zdot_to_unpack+=("${_update_core_files_to_unpack[@]}")
    _dotfiler_plan_zdot_to_remove+=("${_update_core_files_to_remove[@]}")
    return 0
}

# pull: git operations only — no setup.zsh, no new zsh processes.
# Reads topology and remote/branch from _dotfiler_plan_zdot_* vars set by plan.
_zdot_update_hook_pull() {
    local _topology="${_dotfiler_plan_zdot_topology:-}"
    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _remote="${_dotfiler_plan_zdot_remote:-}"
    local _branch="${_dotfiler_plan_zdot_branch:-}"
    local _range="${_dotfiler_plan_zdot_range:-}"

    # Empty range means plan found nothing to do — skip the git operation.
    if [[ -z "$_range" ]]; then
        zdot_log_debug "zdot: no changes planned (topology=${_topology:-unset}), skipping pull"
        return 0
    fi

    case "$_topology" in
        standalone)
            _update_core_prompt_dirty "$_repo_dir" "zdot standalone" || return 1
            zdot_verbose "zdot: pull: git pull --autostash ${_remote} ${_branch}"
            git -C "$_repo_dir" pull -q --autostash "$_remote" "$_branch" || {
                zdot_warn "zdot: pull failed"; return 1
            }
            ;;
        submodule)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
             local _rel="${${_repo_dir:A}#${_parent:A}/}"
             zdot_log_debug "zdot: pull: parent=${_parent}"
             local _stashed=0
             _update_core_maybe_stash "$_parent" "zdot submodule" || return 1
             _stashed=$REPLY
             zdot_verbose "zdot: pull: git submodule update --remote -- ${_rel}"
             local _sub_out _sub_rc
             _sub_out=$(git -C "$_parent" submodule update --remote -- "$_rel" 2>&1)
             _sub_rc=$?
             zdot_log_debug "zdot: pull: submodule output: ${_sub_out}"
             if (( _sub_rc != 0 )); then
                 (( _stashed )) && _update_core_pop_stash "$_parent" "zdot submodule"
                 zdot_warn "zdot: submodule update failed"
                 return 1
             fi
             (( _stashed )) && _update_core_pop_stash "$_parent" "zdot submodule"
             ;;
         subtree)
             local _parent
             _update_core_get_parent_root "$_repo_dir"
             _parent="${reply[1]}"
             local _rel="${${_repo_dir:A}#${_parent:A}/}"
             zdot_verbose "zdot: pull: git subtree pull --prefix=${_rel} ${_remote} ${_branch} --squash"
             zdot_log_debug "zdot: pull: parent=${_parent}"
             local _stashed=0
             _update_core_maybe_stash "$_parent" "zdot subtree" || return 1
             _stashed=$REPLY
             local _subtree_out _subtree_rc
             _subtree_out=$(git -C "$_parent" subtree pull \
                 --prefix="$_rel" "$_remote" "$_branch" --squash 2>&1)
             _subtree_rc=$?
             zdot_log_debug "zdot: pull: subtree output: ${_subtree_out}"
             (( _stashed )) && _update_core_pop_stash "$_parent" "zdot subtree"
             if (( _subtree_rc != 0 )); then
                 zdot_warn "zdot: subtree pull failed"; return 1
             fi
            ;;
        subdir)
            zdot_verbose "zdot: subdir topology — parent repo manages updates"
            return 0
            ;;
        *)
            zdot_warn "zdot: unhandled topology '${_topology}' in pull"
            return 1
            ;;
    esac
    return 0
}

# unpack: setup.zsh for zdot files — called after ALL pulls complete.
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
            zdot_verbose "zdot: removing symlink ${_dest}"
            _update_safe_rm "$_dest"
        else
            zdot_warn "zdot: ${_dest} is not a symlink, not removing"
        fi
    done

    [[ ${#_to_unpack[@]} -eq 0 ]] && return 0

    # Source setup_core.zsh in a subshell — same pattern as _update_main_unpack.
    # Namespace is discarded on exit; setup_core_unload is belt-and-braces.
    # -U = force-unpack, -u = normal. force[] comes from update.zsh's
    # _update_parse_args; empty in shell-hook path (correct: never force at startup).
    local _unpack_flag="-u"
    [[ ${#force[@]} -gt 0 ]] && _unpack_flag="-U"

    local -a _setup_args=(
        "$_unpack_flag"
        ${dry_run:+"-D"}
        ${quiet:+"-q"}
        ${debug_flag:+"-g"}
        --repo-dir "${_repo_dir}"
        --link-dest "${_link_dest}"
        --excludes "${_zdot_dotfiler_scripts_dir}/dotfiler_exclude"
        --excludes "${ZDOT_REPO}/zdot_exclude"
        "${_to_unpack[@]}"
    )
    # Subshell — namespace discarded on exit.
    # setup_core.zsh is sourced early by the caller (update.zsh / setup.zsh);
    # functions are inherited into this subshell.
    (
        if ! (( $+functions[setup_core_main] )); then
            warn "setup_core_main not defined — was setup_core.zsh sourced by the caller?"
            return 1
        fi
        setup_core_main "${_setup_args[@]}"
    )
    return $?
}

# post: commit parent pointer, write SHA marker if subtree.
_zdot_update_hook_post() {
    local _topology="${_dotfiler_plan_zdot_topology:-}"
    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _range="${_dotfiler_plan_zdot_range:-}"
    local _itc_mode
    _update_core_get_in_tree_commit_mode ':zdot:update'; local _itc_mode=$REPLY

    # No range means plan found nothing to do — no pointer to commit.
    if [[ -z "$_range" ]]; then
        zdot_log_debug "zdot: no changes planned (topology=${_topology:-unset}), skipping post"
        return 0
    fi

    case "$_topology" in
        submodule)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            local _new="${_dotfiler_plan_zdot_range#*..}"
            zdot_log_debug "zdot: post: submodule parent=${_parent} rel=${_rel} new=${_new[1,12]}"
            _update_core_commit_parent "$_parent" "$_rel" \
                "submodule pointer updated" \
                "zdot: update submodule to ${_new[1,12]}" \
                "$_itc_mode"
            ;;
        subtree)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            local _remote="${_dotfiler_plan_zdot_remote}"
            local _branch="${_dotfiler_plan_zdot_branch}"
            local _remote_url _pulled_sha
            _remote_url=$(git -C "$_repo_dir" \
                config "remote.${_remote}.url" 2>/dev/null)
            _pulled_sha=$(_update_core_resolve_remote_sha \
                "$_remote_url" "$_branch" 2>/dev/null)
            if [[ -n "$_pulled_sha" ]]; then
                zdot_log_debug "zdot: post: writing SHA marker ${_pulled_sha[1,12]}"
                _update_core_write_sha_marker "$_repo_dir" "$_pulled_sha"
            fi
            _update_core_sha_marker_path "$_repo_dir"
            local _marker_path="$REPLY"
            if [[ "$_itc_mode" != none && -f "$_marker_path" ]]; then
                git -C "$_parent" add "$_marker_path" 2>/dev/null
            fi
            zdot_log_debug "zdot: post: subtree parent=${_parent} rel=${_rel}"
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
                zdot_log_debug "zdot: post: writing ext SHA marker ${_pulled_sha[1,12]}"
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
            zdot_verbose "zdot: post: subdir topology — parent repo tracks versioning"
            ;;
        *)
            zdot_verbose "zdot: post: unknown topology '${_topology}' — nothing to do"
            ;;
    esac
    return 0
}


# setup: full unpack for `dotfiler setup --all` / `dotfiler setup --component zdot`.
# Unlike unpack (which receives a file list from the update plan), this
# unpacks everything — used for bootstrap and force re-link.
# Receives:
#   $1        — "unpack" or "force-unpack"
#   $2 .. $N  — passthrough flags (--dry-run, --quiet, --debug, --yes, --no)
_zdot_update_hook_setup() {
    local _mode=${1:-unpack}
    shift
    local -a _extra_flags=("$@")
    local _link_tree
    zstyle -s ':zdot:update' link-tree _link_tree || _link_tree=true
    [[ "$_link_tree" == false ]] && return 0

    local _link_dest="${XDG_CONFIG_HOME:-$HOME/.config}/zdot"
    local _unpack_flag="-u"
    [[ "$_mode" == "force-unpack" ]] && _unpack_flag="-U"

    local -a _setup_args=(
        "$_unpack_flag"
        "${_extra_flags[@]}"
        --repo-dir "$ZDOT_REPO"
        --link-dest "$_link_dest"
        --excludes "${_zdot_dotfiler_scripts_dir}/dotfiler_exclude"
        --excludes "${ZDOT_REPO}/zdot_exclude"
    )
    # Subshell — namespace discarded on exit.
    # setup_core.zsh is sourced early by the caller (update.zsh / setup.zsh);
    # functions are inherited into this subshell.
    (
        if ! (( $+functions[setup_core_main] )); then
            warn "setup_core_main not defined — was setup_core.zsh sourced by the caller?"
            return 1
        fi
        setup_core_main "${_setup_args[@]}"
    )
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
        "$_topology" \
        _zdot_update_hook_setup
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
    _update_core_get_update_frequency ':zdot:update'; local _freq=$REPLY
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
    zdot_verbose "zdot: shell-hook update: mode=${_mode}"
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
        zdot_warn "zdot: plan failed"
        _update_core_write_timestamp "$_ts" 1 "Plan failed"
        _update_core_release_lock "$_lock_dir"
        return 1
    }
    if [[ -z "${_dotfiler_plan_zdot_range:-}" ]]; then
        # Nothing to do (old==new)
        zdot_log_debug "zdot: shell-hook: nothing to do (old==new)"
        _update_core_write_timestamp "$_ts"
        _update_core_release_lock "$_lock_dir"
        return 0
    fi
    zdot_verbose "zdot: shell-hook: range=${_dotfiler_plan_zdot_range} topology=${_dotfiler_plan_zdot_topology}"

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
        zdot_warn "zdot: pull failed"
        _update_core_write_timestamp "$_ts" 1 "Pull failed"
        _update_core_release_lock "$_lock_dir"
        return 1
    }

    # 10. Unpack — setup.zsh sourced in subshell; all repos at new HEAD
    _zdot_update_hook_unpack || {
        zdot_warn "zdot: unpack failed"
        _update_core_write_timestamp "$_ts" 1 "Unpack failed"
        _update_core_release_lock "$_lock_dir"
        return 1
    }

    # 11. Post — commit parents, SHA markers etc.
    _zdot_update_hook_post || {
        zdot_warn "zdot: post-update steps failed (non-fatal)"
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
#     _zdot_update_handle_update — IS the shell-hook body
#   Unsets bootstrap / registration helpers not needed at runtime.

_zdot_update_impl_cleanup_hook() {
    # If dotfiler-hook.zsh defined zdot_* shims, remove them now.
    if (( ${_zdot_hook_defined_log_shims:-0} )); then
        unset -f zdot_warn zdot_info zdot_error zdot_verbose zdot_log_debug 2>/dev/null
        unset _zdot_hook_defined_log_shims
    fi
    unset -f \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_hook_check \
        _zdot_update_hook_plan \
        _zdot_update_hook_pull \
        _zdot_update_hook_unpack \
        _zdot_update_hook_post \
        _zdot_update_hook_setup \
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
    # _zdot_update_handle_update — kept (IS the hook body)
    return 0
}
