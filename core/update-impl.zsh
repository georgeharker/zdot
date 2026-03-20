# core/update-impl.zsh
# zdot update implementation — pure functions, no side effects at source time.
#
# Callers must:
#   1. Set ZDOT_DIR (linktree path) and ZDOT_REPO (real repo path) before sourcing this file.
#   2. Set _zdot_dotfiler_scripts_dir to the dotfiler scripts path.
#   3. Source update_core.zsh before calling hook functions that need _update_core_* primitives
#      (not required at source time — see shell-side mirrors below).
#   4. Define zdot_warn / zdot_info / zdot_error / zdot_verbose shims (only called at runtime).
#
# Shell-side mirrors of update_core.zsh primitives
# -------------------------------------------------
# Two functions in this file duplicate logic from dotfiler/update_core.zsh so
# that update-impl.zsh can be sourced into the live shell WITHOUT pulling
# update_core.zsh into the shell namespace (it is heavy; we source it only
# inside subshells where the namespace is discarded on exit).
#
# Each mirror self-defers to the real update_core function if it is already
# loaded, so there is no divergence risk when called from inside a subshell:
#
#   Shell-side mirror                  →  update_core.zsh counterpart
#   _zdot_update_get_parent_root          _update_core_get_parent_root
#   _zdot_update_find_dotfiler_scripts    (no direct counterpart — extended version)
#
# Keep the raw-git logic in these mirrors in sync with update_core.zsh.
#
# Public entry points:
#   _zdot_update_get_parent_root         → reply[] = (root type); rc 0
#   _zdot_update_find_dotfiler_scripts   → REPLY = scripts dir; rc 0/1
#   _zdot_update_is_dotfiler_integration → returns 0 if dotfiler manages zdot updates
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
# Shell-side mirror of _update_core_get_parent_root (update_core.zsh)
# ---------------------------------------------------------------------------
# Returns the parent repo root for a given repo directory.
# Sets reply[] = ( <root-path> <topology> ) where topology is one of:
#   superproject  — repo is a registered git submodule
#   toplevel      — repo shares a parent git root (subtree / subdir)
#   none          — repo is its own git root (standalone)
#
# Self-defers to _update_core_get_parent_root if update_core.zsh is loaded.
# Keep the raw-git fallback in sync with that function.

_zdot_update_get_parent_root() {
    if (( ${+functions[_update_core_get_parent_root]} )); then
        _update_core_get_parent_root "$@"; return
    fi
    local _repo_dir=$1 _root
    reply=()
    _root=$(git -C "$_repo_dir" rev-parse --show-superproject-working-tree 2>/dev/null)
    if [[ -n "$_root" ]]; then
        reply=( ${_root:A} superproject ); return 0
    fi
    _root=$(git -C "$_repo_dir" rev-parse --show-toplevel 2>/dev/null) || {
        reply=( "" none ); return 0
    }
    reply=( ${_root:A} toplevel ); return 0
}

# ---------------------------------------------------------------------------
# Shell-side mirror of dotfiler scripts detection (3-step priority)
# ---------------------------------------------------------------------------
# Sets REPLY to the dotfiler scripts directory; returns 0/1.
# No direct update_core.zsh counterpart — this is an extended version that
# falls back to cloning dotfiler from the plugin cache when not yet present.
# Step 2 self-defers via _zdot_update_get_parent_root (above).

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
    _zdot_update_get_parent_root "$ZDOT_REPO"; _root=${reply[1]}
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

# ---------------------------------------------------------------------------
# Dotfiler integration detection
# ---------------------------------------------------------------------------
# Returns 0 (true) if dotfiler is responsible for updating zdot, i.e.:
#   - ':zdot:update' dotfiler-integration is explicitly 'true'/'yes', OR
#   - (default) zdot lives inside a parent repo that contains dotfiler scripts.
# Returns 1 (false) if dotfiler-integration is explicitly 'false'/'no', or
#   zdot is genuinely standalone (no parent dotfiler repo found).
#
# This drives two gates:
#   1. zdot/core/update.zsh: skip zdot_register_hook (shell-hook) when true —
#      dotfiler is responsible for the update lifecycle.
#
# In both paths, setup_core_main is available without extra sourcing at startup:
#   - dotfiler path: dotfiler/update.zsh sources setup_core.zsh before hooks run.
#   - shell-hook path: _zdot_update_shell_hook (zdot/core/update.zsh) sources
#     setup_core.zsh inside a subshell before calling _zdot_update_handle_update.

_zdot_update_is_dotfiler_integration() {
    # Explicit override wins unconditionally.
    local _explicit
    zstyle -s ':zdot:update' dotfiler-integration _explicit 2>/dev/null
    case "${_explicit:-}" in
        true|yes|on|1)   return 0 ;;
        false|no|off|0)  return 1 ;;
    esac

    # Default: detect from the parent repo via the shell-side mirror.
    # _zdot_update_get_parent_root self-defers to _update_core_get_parent_root
    # if update_core.zsh is already loaded (e.g. inside a subshell), so this
    # works correctly both at source time and at hook-run time.
    local _parent_root
    _zdot_update_get_parent_root "$ZDOT_REPO"; _parent_root=${reply[1]}
    [[ -n "$_parent_root" \
        && -f "${_parent_root}/.nounpack/dotfiler/update_core.zsh" ]]
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
#
# Topology semantics mirror _update_core_is_dotfiler_available in update_core.zsh:
#   standalone  — zdot is its own top-level repo; fetch + compare
#   submodule   — zdot is a submodule; fetch submodule remote + compare
#                 (surfaces upstream-ahead changes before parent bumps pointer)
#   subtree     — zdot merged via git-subtree; compare SHA marker vs remote
#   subdir      — plain subdirectory inside parent repo; the parent repo check
#                 in is_update_available() already covers this — nothing extra
#   none|*      — not a git repo; nothing to check
#
# NOTE: this function models Phase 2 (self-directed: is zdot upstream ahead?).
# Phase 1 (parent-directed: did dotfiles move its zdot pointer?) is covered by
# the _update_core_is_available(dotfiles_dir) check in is_update_available().
# The two checks are intentionally asymmetric — together they cover both phases.
_zdot_update_hook_check() {
    local _subtree_spec _subtree_url
    _zdot_update_init

    _update_core_detect_deployment "$ZDOT_REPO" "$_subtree_spec"
    local _topology="$REPLY"

    case $_topology in
        subtree)
            # scope ':zdot:update': apply release-channel constraint (default: tags).
            _update_core_is_available_subtree "$ZDOT_REPO" "$_subtree_spec" "$_subtree_url" \
                ':zdot:update'
            return $?
            ;;
        standalone|submodule)
            # Compare zdot's own HEAD against remote.
            # allow_diverged=1: warn and proceed rather than treating diverged as error.
            # scope ':zdot:update': apply release-channel constraint (default: tags).
            _update_core_is_available "$ZDOT_REPO" "" 1 ':zdot:update'
            return $?
            ;;
        subdir|none|*)
            # Parent repo manages zdot; is_update_available()'s main repo check covers it.
            return 1
            ;;
    esac
}

# plan: populate _dotfiler_plan_zdot_* directly in the caller's process.
# Called pre-pull. Does NOT modify any git state.
# Returns 0 always. "Nothing to do" = _dotfiler_plan_zdot_range is empty/unset.
# Caller must pre-declare: typeset -gaU _dotfiler_plan_zdot_to_unpack
#                                        _dotfiler_plan_zdot_to_remove
# Args: [--phase=dotfiles|components]
#   --phase=dotfiles  : caller has set _dotfiler_hint_range_zdot from dotfiles refs;
#                       target SHA is pinned to that hint.
#   --phase=components: self-directed; fetches own remote tip.
_zdot_update_hook_plan() {
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }

    # Declare plan arrays unconditionally at the top so every early return and
    # every caller path sees them as valid empty arrays rather than unset vars.
    typeset -gaU _dotfiler_plan_zdot_to_unpack _dotfiler_plan_zdot_to_remove

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
        # Phase dotfiles: hint range set by dotfiler from dotfiles refs.
        # _old and _new are the zdot SHAs extracted from the dotfiles submodule
        # pointer — old is what dotfiles previously recorded, new is the target.
        _old="${_dotfiler_hint_range_zdot%%..*}"
        _new="${_dotfiler_hint_range_zdot#*..}"
        zdot_verbose "zdot hook plan: phase=dotfiles, hint=${_dotfiler_hint_range_zdot}"
        # _old/_new come from the hint — we only need remote/branch for pull phase.
        _remote=$(_update_core_get_default_remote "$ZDOT_REPO")
        _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
        # Fetch to materialise _new objects locally for build_file_lists.
        local _fetch_err
        _fetch_err=$(git -C "$ZDOT_REPO" fetch -q "$_remote" "$_branch" 2>&1 >/dev/null) || \
            log_debug "zdot: plan: fetch ${_remote}/${_branch} failed: ${_fetch_err}"
    elif [[ "$_phase" == components ]]; then
        # Phase components: self-directed. No hint; fetch own remote, advance to tip.
        # _update_core_component_tip_range handles topology differences:
        #   subtree    — current position is SHA marker, not HEAD
        #   standalone | submodule — current position is HEAD
        zdot_info "Checking zdot..."
        local _remote_url=""
        if [[ "$_topology" == subtree ]]; then
            _update_core_resolve_subtree_spec "$ZDOT_REPO" "$_subtree_spec" \
                "$_subtree_url" || return 0
            _remote="${reply[1]}" _branch="${reply[2]}" _remote_url="${reply[3]}"
        else
            _remote=$(_update_core_get_default_remote "$ZDOT_REPO")
            _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
        fi
        _update_core_component_tip_range \
            "$ZDOT_REPO" "$_topology" "${_remote_url:-}" "${_branch:-}" \
            --scope ':zdot:update' || return 0
        if [[ -z "$REPLY" ]]; then
            if (( ! ${_force:-0} )); then
                zdot_info "zdot: up to date"
                return 0
            fi
            zdot_verbose "zdot hook plan: up to date but force active — populating plan vars"
            _new="$_old"
        else
            _old="${REPLY%%..*}"
            _new="${REPLY#*..}"
        fi
    else
        # Phase dotfiles but no hint — dotfiles has no zdot change recorded.
        if (( ! ${_force:-0} )); then
            # Nothing for zdot to do in this phase.
            return 0
        fi
        zdot_verbose "zdot hook plan: no hint but force active — populating plan vars"
        _remote=$(_update_core_get_default_remote "$ZDOT_REPO")
        _branch=$(_update_core_get_default_branch "$ZDOT_REPO" "$_remote")
        _new="$_old"
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
    _dotfiler_plan_zdot_pull_outcome=skip

    # Nothing changed — topology is set but range stays empty.
    if [[ "$_old" == "$_new" ]]; then
        if (( ! ${_force:-0} )); then
            zdot_log_debug "zdot hook plan: topology=${_topology}, nothing to do (${_old[1,12]})"
            _dotfiler_plan_zdot_range=""
            return 0
        fi
        zdot_log_debug "zdot hook plan: old==new (${_old[1,12]}) but force active"
    fi

    zdot_verbose "zdot hook plan: topology=${_topology} old=${_old[1,12]} new=${_new[1,12]}"

    # Build file lists using the shared update_core helper
    typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
    _update_core_build_file_lists "$ZDOT_REPO" "${_old}..${_new}" || \
        zdot_warn "zdot: file list unavailable — unpack may be incomplete"

    local _nu=${#_update_core_files_to_unpack[@]}
    local _nr=${#_update_core_files_to_remove[@]}
    if (( _nu > 0 || _nr > 0 )); then
        zdot_info "zdot: ${_nu} files to update, ${_nr} files to remove"
    fi

    _dotfiler_plan_zdot_range="${_old}..${_new}"
    _dotfiler_plan_zdot_to_unpack+=("${_update_core_files_to_unpack[@]}")
    _dotfiler_plan_zdot_to_remove+=("${_update_core_files_to_remove[@]}")
    return 0
}

# pull: git operations only — no setup.zsh, no new zsh processes.
# Reads topology and remote/branch from _dotfiler_plan_zdot_* vars set by plan.
# Args: [--phase=dotfiles|components]
#   --phase=dotfiles  : pull to exactly the SHA recorded in dotfiles (range's new
#                       end). Ensures Phase 1 reproducibility.
#   --phase=components: pull to remote/branch tip (Phase 2 / standalone shell-hook).
_zdot_update_hook_pull() {
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }

    local _topology="${_dotfiler_plan_zdot_topology:-}"
    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _remote="${_dotfiler_plan_zdot_remote:-}"
    local _branch="${_dotfiler_plan_zdot_branch:-}"
    local _range="${_dotfiler_plan_zdot_range:-}"

    # Reset outcome from any prior run.
    _dotfiler_plan_zdot_pull_outcome=skip

    # Resolve pull target: dotfiles phase pins to exact SHA, components phase uses tip.
    local _target_ref="${_remote}/${_branch}"
    if [[ "$_phase" == dotfiles ]] && [[ -n "$_range" ]]; then
        _target_ref="${_range#*..}"
    fi

    # Empty range means plan found nothing to do — skip the git operation.
    if [[ -z "$_range" ]]; then
        zdot_log_debug "zdot: no changes planned (topology=${_topology:-unset}), skipping pull"
        zdot_info "zdot: up to date"
        return 0
    fi

    zdot_info "zdot: pulling..."
    case "$_topology" in
        standalone)
            _update_core_component_pull_standalone \
                "$_repo_dir" "$_target_ref" "$_remote" "$_branch" "$_phase" || {
                zdot_warn "zdot: pull failed"
                return 1
            }
            _dotfiler_plan_zdot_pull_outcome=$REPLY
            (( ${_dry_run:-0} )) && zdot_info "zdot: [dry-run] pull skipped" || zdot_info "zdot: updated"
            ;;
        submodule)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            zdot_log_debug "zdot: pull: parent=${_parent} target=${_target_ref}"
            _update_core_component_pull_submodule \
                "$_parent" "$_rel" "$_target_ref" "$_phase" || {
                zdot_warn "zdot: submodule update failed"
                return 1
            }
            _dotfiler_plan_zdot_pull_outcome=$REPLY
            (( ${_dry_run:-0} )) && zdot_info "zdot: [dry-run] pull skipped" || zdot_info "zdot: updated"
            ;;
        subtree)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            zdot_log_debug "zdot: pull: parent=${_parent} target=${_target_ref}"
            _update_core_component_pull_subtree \
                "$_parent" "$_rel" "$_remote" "$_branch" "$_phase" || {
                zdot_warn "zdot: subtree pull failed"
                return 1
            }
            _dotfiler_plan_zdot_pull_outcome=$REPLY
            (( ${_dry_run:-0} )) && zdot_info "zdot: [dry-run] pull skipped" || zdot_info "zdot: updated"
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
    # Required caller-scoped variables (set by update.zsh _update_parse_args
    # in the dotfiler path, or empty/unset in the shell-hook path):
    #   force[]     — non-empty array → force unpack (-U)
    #   dry_run     — non-empty string → dry-run mode (-D)
    #   quiet       — non-empty string → quiet mode (-q)
    #   debug_flag  — non-empty string → debug mode (-g)
    # Required functions (from update_core.zsh):
    #   _update_core_safe_rm
    # Required functions (from setup_core.zsh, inherited in subshell):
    #   setup_core_main
    local _link_tree
    zstyle -s ':zdot:update' link-tree _link_tree || _link_tree=true
    [[ "$_link_tree" == false ]] && return 0

    # Skip if plan found nothing to unpack — setup only processes explicitly
    # listed files, so empty lists is a genuine no-op regardless of range.
    if [[ ${#_dotfiler_plan_zdot_to_unpack[@]} -eq 0 \
        && ${#_dotfiler_plan_zdot_to_remove[@]} -eq 0 \
        && ${#force[@]} -eq 0 ]]; then
        zdot_log_debug "zdot: unpack skipping — no files planned and not forced"
        return 0
    fi

    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _link_dest="${_dotfiler_plan_zdot_link_dest:-${XDG_CONFIG_HOME:-$HOME/.config}/zdot}"
    local -a _to_unpack=("${_dotfiler_plan_zdot_to_unpack[@]}")
    local -a _to_remove=("${_dotfiler_plan_zdot_to_remove[@]}")

    # Remove deleted symlinks
    local _f _dest
    for _f in "${_to_remove[@]}"; do
        _dest="${_link_dest}/${_f}"
        if [[ -L "$_dest" ]]; then
            zdot_verbose "zdot: removing symlink ${_dest}"
            _update_core_safe_rm "$_dest"
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
        --excludes "${ZDOT_REPO}/zdot_exclude"
        "${_to_unpack[@]}"
    )
    # Subshell — namespace discarded on exit.
    # setup_core_main is inherited from the calling context:
    #   - dotfiler path: dotfiler/update.zsh sources setup_core.zsh before hooks.
    #   - shell-hook path: _zdot_update_shell_hook sources setup_core.zsh into
    #     the subshell before calling _zdot_update_handle_update.
    (
        if ! (( $+functions[setup_core_main] )); then
            warn "setup_core_main not defined — setup_core.zsh was not sourced by caller"
            return 1
        fi
        setup_core_main "${_setup_args[@]}"
    )
    return $?
}

# post: commit parent pointer, write SHA marker if subtree/standalone.
# Args: [--phase=dotfiles|components]
#   --phase=dotfiles  : Phase 1 — write stamps only. Dotfiles already
#                       authoritative; do NOT create a new dotfiles commit.
#   --phase=components: Phase 2 — write stamps + update dotfiles marker/pointer
#                       + commit dotfiles to record the new component SHA.
_zdot_update_hook_post() {
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }

    local _topology="${_dotfiler_plan_zdot_topology:-}"
    local _repo_dir="${_dotfiler_plan_zdot_repo_dir:-$ZDOT_REPO}"
    local _range="${_dotfiler_plan_zdot_range:-}"
    local _outcome="${_dotfiler_plan_zdot_pull_outcome:-skip}"
    local _itc_mode
    _update_core_get_in_tree_commit_mode ':zdot:update'; _itc_mode=$REPLY

    # No range means plan found nothing to do — no pointer to commit.
    if [[ -z "$_range" ]]; then
        zdot_log_debug "zdot: no changes planned (topology=${_topology:-unset}), skipping post"
        return 0
    fi

    local _new="${_range#*..}"

    case "$_topology" in
        submodule|subtree|standalone)
            local _parent
            _update_core_get_parent_root "$_repo_dir"
            _parent="${reply[1]}"
            local _rel="${${_repo_dir:A}#${_parent:A}/}"
            zdot_log_debug "zdot: post: parent=${_parent} rel=${_rel} new=${_new[1,12]} phase=${_phase} outcome=${_outcome}"
            _update_core_component_post_marker \
                "$_repo_dir" "$_parent" "$_rel" "$_new" \
                "$_topology" "$_itc_mode" "$_phase" "$_outcome" || {
                zdot_warn "zdot: post marker/commit failed"
                return 1
            }
            ;;
        subdir)
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
        --excludes "${ZDOT_REPO}/zdot_exclude"
    )
    # Subshell — namespace discarded on exit.
    # Same assumption as _zdot_update_hook_unpack: setup_core_main is
    # inherited from the calling context.
    (
        if ! (( $+functions[setup_core_main] )); then
            warn "setup_core_main not defined — setup_core.zsh was not sourced by caller"
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
        _zdot_update_get_parent_root \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_is_dotfiler_integration \
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
        _zdot_update_get_parent_root \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_is_dotfiler_integration \
        _zdot_update_hook_register \
        _zdot_update_impl_cleanup_hook \
        _zdot_update_impl_cleanup_shell \
        2>/dev/null
    # _zdot_update_hook_{check,plan,pull,unpack,post} — kept (called by _zdot_update_handle_update)
    # _zdot_update_handle_update — kept (called by _zdot_update_shell_hook)
    # _zdot_update_shell_hook — kept (IS the registered hook body, defined in update.zsh)
    return 0
}
