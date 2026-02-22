#!/usr/bin/env zsh
# core/plugins: Lightweight plugin manager
# Declares plugins with zdot_use, loads on-demand with zdot_load_plugin

# ============================================================================
# Global State
# ============================================================================

typeset -ga _ZDOT_PLUGINS_ORDER   # Ordered list of plugin specs
typeset -gA _ZDOT_PLUGINS        # plugin spec -> kind (normal/defer/fpath/path)
typeset -gA _ZDOT_PLUGINS_LOADED # plugin spec -> 1 (already loaded)
typeset -gA _ZDOT_PLUGIN_COMPILE_EXTRA # plugin spec -> space-separated list of extra files to compile
typeset -gA _ZDOT_PLUGINS_VERSION # plugin spec -> version/rev (optional)
typeset -gA _ZDOT_PLUGINS_PATH   # plugin spec -> filesystem path (populated at clone time)
typeset -gA _ZDOT_PLUGINS_FILE   # plugin spec -> *.plugin.zsh path (populated at load time)
typeset -g  _ZDOT_PLUGINS_CACHE  # cache directory
typeset -g  _ZDOT_PLUGINS_INITIALIZED=0
typeset -ga _ZDOT_BUNDLE_HANDLERS # Ordered list of registered bundle handler names
typeset -ga _ZDOT_BUNDLE_REPOS    # Repos cloned as bundle dependencies (not user plugins)
typeset -ga _ZDOT_DEFER_CMDS        # [N] = command string submitted
typeset -ga _ZDOT_DEFER_HOOKS       # [N] = hook_func that submitted it (or "?" if outside hook)
typeset -ga _ZDOT_DEFER_DELAYS      # [N] = delay in seconds (0 if none)
typeset -ga _ZDOT_DEFER_SPECS       # [N] = human-readable spec name (plugins), "__sentinel__", or ""
typeset -ga _ZDOT_DEFER_LABELS      # [N] = explicit --label override (or "" if none)
typeset -g  _ZDOT_DEFER_COUNTER=0
typeset -g  _ZDOT_DEFER_SKIP_RECORD=0  # suppress generic recording when zdot_load_deferred_plugins records inline

# _zdot_defer_record — append one deferred-command entry to the display log.
#
# This function does NOT schedule execution; it only records metadata for
# inspection via `zdot_show_defer_queue`.  The four parallel arrays hold one
# element per deferred item:
#
#   _ZDOT_DEFER_CMDS    — the command string that will be deferred
#   _ZDOT_DEFER_HOOKS   — the hook_N id of the hook that submitted the defer
#                         (captured from $_ZDOT_CURRENT_HOOK_FUNC at call time)
#   _ZDOT_DEFER_DELAYS  — the delay value passed to zsh-defer (or "" for none)
#   _ZDOT_DEFER_SPECS   — the plugin spec string (or "" if not inside a plugin)
#
# _ZDOT_DEFER_COUNTER tracks the total count (== length of each array).
#
# Callers set _ZDOT_DEFER_SKIP_RECORD=1 when they need to enqueue a command
# via zdot_defer but have already called _zdot_defer_record manually (e.g. the
# compinit special case), to prevent double-recording.
_zdot_defer_record() {
    (( _ZDOT_DEFER_COUNTER++ ))
    _ZDOT_DEFER_CMDS+=( "$1" )
    _ZDOT_DEFER_HOOKS+=( "${_ZDOT_CURRENT_HOOK_FUNC:-?}" )
    _ZDOT_DEFER_DELAYS+=( "$2" )
    _ZDOT_DEFER_SPECS+=( "$3" )
    _ZDOT_DEFER_LABELS+=( "${4:-}" )
}

# Display the Defer Order Constraints section (shared by hooks_list and phases_list).
_zdot_defer_order_display() {
    if [[ ${#_ZDOT_DEFER_ORDER_PAIRS[@]} -gt 0 ]]; then
        zdot_info "Defer Order Constraints:"
        zdot_info ""
        local _pi=1
        while [[ $_pi -lt ${#_ZDOT_DEFER_ORDER_PAIRS[@]} ]]; do
            local _fn="${_ZDOT_DEFER_ORDER_PAIRS[$_pi]}"
            local _tn="${_ZDOT_DEFER_ORDER_PAIRS[$(( _pi + 1 ))]}"
            (( _pi += 2 ))
            zdot_info "  $_fn → $_tn"
        done
        zdot_info ""
    fi
}

# Set _name_mark and _deferred_mark for a given hook_id/func pair.
# Usage: _zdot_hook_display_marks <hook_id> <func>
# Sets: _name_mark, _deferred_mark (in caller's scope, no local)
_zdot_hook_display_marks() {
    local _hname="${_ZDOT_HOOK_NAMES[$1]:-$2}"
    _name_mark=""
    [[ "$_hname" != "$2" ]] && _name_mark=" [name: $_hname]"
    _deferred_mark=""
    [[ ${_ZDOT_DEFERRED_HOOKS[(Ie)$1]} -gt 0 ]] && _deferred_mark=" [deferred]"
}

# Set defer_mark based on whether any hook in the id list ran deferred work.
# Usage: _zdot_ran_deferred_mark "${id_list[@]}"
# Sets: defer_mark (in caller's scope, no local)
_zdot_ran_deferred_mark() {
    local _rd=0
    local _id
    for _id in "$@"; do
        local _f="${_ZDOT_HOOKS[$_id]}"
        [[ " ${_ZDOT_DEFER_HOOKS[@]} " =~ " ${_f} " ]] && _rd=1 && break
    done
    defer_mark=""
    [[ $_rd -eq 1 ]] && defer_mark=" [ran deferred]"
}

# ============================================================================
# Plugin Rev Stamp
# ============================================================================

typeset -g _ZDOT_PLUGINS_REV_STAMP

_zdot_plugins_rev_stamp_init() {
    [[ -n "$_ZDOT_PLUGINS_REV_STAMP" ]] && return 0
    local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot"
    _ZDOT_PLUGINS_REV_STAMP="${cache_dir}/plugin-revs.zsh"
}

# zdot_plugins_have_changed — check whether any git-sourced plugin has a new HEAD.
#
# Algorithm:
#   1. Load the previously saved per-plugin HEAD revisions from the stamp file
#      ($zdot_plugin_revs_file, typically plugin-revs.zsh inside the cache dir).
#      The stamp file is a sourced zsh snippet that populates _ZDOT_PLUGINS_SAVED_REV.
#   2. Iterate every plugin spec in _ZDOT_PLUGINS_PATH.  For specs that point to
#      a git repository, run `git rev-parse HEAD` to get the current commit.
#   3. Compare each current rev against the saved rev for that spec.
#      If any differ, the function:
#        a. Overwrites the stamp file atomically with the new set of revisions.
#        b. Returns 0 (changed).
#   4. If all revisions match, returns 1 (unchanged).
#
# This is used by the cache layer to decide whether plugin-generated cache
# entries (e.g. fpath fragments, completion scripts) need to be regenerated.
# Non-git plugins (local paths without a .git dir) are skipped — they are
# assumed to be managed externally and not tracked by revision.
zdot_plugins_have_changed() {
    _zdot_plugins_rev_stamp_init
    typeset -gA _ZDOT_PLUGINS_SAVED_REV
    [[ -r "$_ZDOT_PLUGINS_REV_STAMP" ]] && source "$_ZDOT_PLUGINS_REV_STAMP"
    local changed=0
    local spec path current_rev
    typeset -gA _ZDOT_PLUGINS_CURRENT_REV
    for spec in ${(k)_ZDOT_PLUGINS_PATH}; do
        path="${_ZDOT_PLUGINS_PATH[$spec]}"
        [[ -d "$path/.git" ]] || continue
        current_rev=$(git -C "$path" rev-parse HEAD 2>/dev/null)
        _ZDOT_PLUGINS_CURRENT_REV[$spec]="$current_rev"
        if [[ "$current_rev" != "${_ZDOT_PLUGINS_SAVED_REV[$spec]}" ]]; then
            changed=1
        fi
    done
    if [[ $changed -eq 1 ]]; then
        _ZDOT_PLUGINS_SAVED_REV=("${(kv)_ZDOT_PLUGINS_CURRENT_REV[@]}")
        { typeset -p _ZDOT_PLUGINS_SAVED_REV } >| "$_ZDOT_PLUGINS_REV_STAMP"
        return 0
    fi
    return 1
}

# ============================================================================
# Configuration
# ============================================================================

_zdot_plugins_init() {
    [[ $_ZDOT_PLUGINS_INITIALIZED -eq 1 ]] && return 0
    
    # Get cache directory from zstyle or use default
    local cache_dir
    zstyle -s ':zdot:plugins' directory cache_dir
    
    if [[ -z "$cache_dir" ]]; then
        cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugins"
    fi
    
    _ZDOT_PLUGINS_CACHE="$cache_dir"
    [[ ! -d "$_ZDOT_PLUGINS_CACHE" ]] && mkdir -p "$_ZDOT_PLUGINS_CACHE"
    
    _ZDOT_PLUGINS_INITIALIZED=1
}

# ============================================================================
# Bundle Handler Registry
# ============================================================================

# Register a bundle handler by name.
# The handler must implement:
#   zdot_bundle_<name>_match <spec>   -> return 0 if this handler owns spec
#   zdot_bundle_<name>_path  <spec>   -> print filesystem path for spec
#   zdot_bundle_<name>_clone <spec>   -> ensure plugin is on disk
#   zdot_bundle_<name>_load  <spec>   -> source/activate the plugin
# Usage: zdot_bundle_register <name>
zdot_bundle_register() {
    local name=$1
    [[ -z "$name" ]] && return 1
    # Avoid duplicates
    local h
    for h in $_ZDOT_BUNDLE_HANDLERS; do
        [[ $h == $name ]] && return 0
    done
    _ZDOT_BUNDLE_HANDLERS+=( "$name" )
}

# Find the registered bundle handler that owns <spec>.
# Sets $REPLY to the handler name; returns 1 if none found.
_zdot_bundle_handler_for() {
    local spec=$1
    local name
    for name in $_ZDOT_BUNDLE_HANDLERS; do
        if zdot_bundle_${name}_match "$spec" 2>/dev/null; then
            REPLY=$name
            return 0
        fi
    done
    return 1
}

# ============================================================================
# Public API: zdot_use
# ============================================================================

# Declare a plugin to be available (clone if needed, but don't load)
# Usage: zdot_use <spec> [kind]
#   spec: "omz:lib", "omz:plugins/git", "user/repo", "user/repo@v1.0.0"
#   kind: normal (default), defer, fpath, path
zdot_use() {
    local spec=$1
    local kind=${2:-normal}
    
    if [[ -z "$spec" ]]; then
        zdot_error "zdot_use: plugin spec required"
        return 1
    fi
    
    # Parse version from spec (user/repo@v1.0.0)
    local version=""
    if [[ $spec == *@* ]]; then
        version=${spec##*@}
        spec=${spec%@*}
    fi
    
    # Store with version info if specified
    if [[ -n "$version" ]]; then
        _ZDOT_PLUGINS_VERSION[$spec]=$version
    fi
    
    # Only add to order if not already present
    if [[ -z "${_ZDOT_PLUGINS[$spec]}" ]]; then
        _ZDOT_PLUGINS_ORDER+=$spec
    fi
    _ZDOT_PLUGINS[$spec]=$kind
}

zdot_use_defer() {
    zdot_use "$1" defer
}

zdot_use_fpath() {
    zdot_use "$1" fpath
}

zdot_use_path() {
    zdot_use "$1" path
}

# Register a repo cloned as a bundle dependency (not a user plugin).
# Prevents zdot_clean_plugins from treating it as orphaned.
zdot_use_bundle() {
    local repo=$1
    # Dedup: only append if not already present
    if (( ! ${_ZDOT_BUNDLE_REPOS[(Ie)$repo]} )); then
        _ZDOT_BUNDLE_REPOS+=( "$repo" )
    fi
}

# ============================================================================
# Path Resolution
# ============================================================================

zdot_plugin_path() {
    local spec=$1
    local cache=${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugins}

    # Delegate to bundle handler if one is registered for this spec
    local handler
    _zdot_bundle_handler_for "$spec" && handler=$REPLY && {
        zdot_bundle_${handler}_path "$spec"
        return
    }

    REPLY="$cache/$spec"
}

# ============================================================================
# Plugin Cloning
# ============================================================================

zdot_plugin_clone() {
    local spec=$1
    local cache=${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugins}

    # Delegate to bundle handler if one is registered for this spec
    local handler
    _zdot_bundle_handler_for "$spec" && handler=$REPLY && {
        zdot_bundle_${handler}_clone "$spec"
        # Path is populated by the bundle handler's clone function
        return $?
    }

    local repo=$spec
    local dest="$cache/$repo"
    local version=${_ZDOT_PLUGINS_VERSION[$spec]:-}

    # Cache path in global assoc array — no subshell needed for user/repo specs
    _ZDOT_PLUGINS_PATH[$spec]="$dest"

    [[ -d "$dest" ]] && return 0

    print "zdot-plugins: cloning $repo..." >&2
    git clone --quiet --recurse-submodules "https://github.com/$repo" "$dest"

    # Check out specific version if specified
    if [[ -n "$version" ]]; then
        (cd "$dest" && git checkout --quiet "$version") || {
            print "zdot-plugins: warning: failed to checkout $version for $repo" >&2
        }
    fi
}

# zdot_plugins_clone_all — ensure all plugin repositories are cloned locally.
#
# Fast-path (sentinel check):
#   Builds a canonical string from all plugin specs and versions, then compares
#   it against the contents of the sentinel file ($cache_dir/.cloned).
#   If the string matches AND every expected plugin directory already exists on
#   disk, the function returns 0 immediately without touching git at all.
#   This makes the common case (nothing changed) essentially free.
#
# Slow path:
#   Triggered when the sentinel string differs from the file (a spec was added,
#   removed, or pinned to a different version) or when any plugin directory is
#   missing (e.g. after a fresh checkout).  In the slow path, zdot_plugin_clone
#   is called for each spec individually.  After all clones succeed, the sentinel
#   file is rewritten with the current spec string so future runs hit the fast
#   path again.
#
# The sentinel file is stored inside the plugins cache directory and is not
# version-controlled — it is purely a local optimisation artefact.
zdot_plugins_clone_all() {
    _zdot_plugins_init

    local sentinel="${_ZDOT_PLUGINS_CACHE}/.cloned"

    # Build the sentinel string from specs + version pins so that changing a
    # version pin (e.g. user/repo@v1 → user/repo@v2) invalidates the sentinel
    # and triggers a re-clone.  Specs without a pin appear as plain user/repo.
    local _s _v
    local -a _sentinel_parts
    for _s in $_ZDOT_PLUGINS_ORDER; do
        _v=${_ZDOT_PLUGINS_VERSION[$_s]:-}
        if [[ -n "$_v" ]]; then
            _sentinel_parts+=( "${_s}@${_v}" )
        else
            _sentinel_parts+=( "$_s" )
        fi
    done
    local current_specs="${(j: :)_sentinel_parts}"

    # Fast path: if the sentinel records the exact same spec+version list, all
    # plugins are already on disk — skip all clone-checks entirely.
    if [[ -f "$sentinel" && "$(<$sentinel)" == "$current_specs" ]]; then
        # Populate _ZDOT_PLUGINS_PATH from cache dir without subshells so that
        # zdot_load_deferred_plugins can use it even on the fast path.
        local _fast_spec _fast_cache _fast_all_present=1
        _fast_cache=${_ZDOT_PLUGINS_CACHE}
        for _fast_spec in $_ZDOT_PLUGINS_ORDER; do
            [[ -n "${_ZDOT_PLUGINS_PATH[$_fast_spec]}" ]] && continue
            # Bundle specs (omz:*) are handled by their own handler; skip here.
            # This is safe only because no omz:* spec uses kind=defer — if that
            # ever changes, this skip must be revisited.
            [[ $_fast_spec == *:* ]] && continue
            # If the plugin directory was manually deleted, bail out of the fast
            # path so the slow path can re-clone it.
            if [[ ! -d "${_fast_cache}/${_fast_spec}" ]]; then
                _fast_all_present=0
                break
            fi
            _ZDOT_PLUGINS_PATH[$_fast_spec]="${_fast_cache}/${_fast_spec}"
        done
        [[ $_fast_all_present -eq 1 ]] && return 0
        # Fall through to slow path if any directory was missing.
    fi

    local spec
    for spec in $_ZDOT_PLUGINS_ORDER; do
        zdot_plugin_clone "$spec"
    done

    # Write sentinel so next startup can skip clone-checks
    print -r -- "$current_specs" >| "$sentinel"
}

# ============================================================================
# Plugin Loading (on-demand)
# ============================================================================

# Load a plugin and provide a phase
# Usage: zdot_load_plugin <spec> [--provides <phase>]
zdot_load_plugin() {
    local spec=$1
    local provides_phase=$2
    
    if [[ -z "$spec" ]]; then
        zdot_error "zdot_load_plugin: plugin spec required"
        return 1
    fi
    
    # Already loaded?
    [[ -n "${_ZDOT_PLUGINS_LOADED[$spec]}" ]] && return 0

    # Delegate to bundle handler if one is registered for this spec
    local handler
    _zdot_bundle_handler_for "$spec" && handler=$REPLY && {
        zdot_bundle_${handler}_load "$spec"
        _ZDOT_PLUGINS_LOADED[$spec]=1
        return 0
    }

    zdot_plugin_path "$spec"
    local plugin_path=$REPLY

    if [[ -z "$plugin_path" ]]; then
        zdot_warn "zdot_load_plugin: could not resolve path for $spec"
        return 1
    fi

    local plugin_file
    local kind=${_ZDOT_PLUGINS[$spec]:-normal}

    # Find plugin file
    local -a _plugin_files=( "$plugin_path"/*.plugin.zsh(N) )
    plugin_file=${_plugin_files[1]}

    if [[ -z "$plugin_file" ]]; then
        zdot_warn "zdot_load_plugin: no plugin file for $spec"
        return 1
    fi
    
    # Add to fpath if has functions
    if [[ -d "$plugin_path/functions" ]]; then
        fpath+=( "$plugin_path" )
    fi
    
    # Source the plugin
    source "$plugin_file"
    _ZDOT_PLUGINS_LOADED[$spec]=1
    
    # Optionally compile plugin to .zwc for faster loading (opt-out: enabled by default)
    if zstyle -T ':zdot:plugins' compile; then
        zdot_plugin_compile "$spec"
    fi
    
    return 0
}

# Compile a plugin's .zsh files to .zwc bytecode
# Uses zdot_cache_compile_file for each file
zdot_plugin_compile() {
    local spec=$1
    zdot_plugin_path "$spec"
    local plugin_path=$REPLY

    [[ -d "$plugin_path" ]] || return 1

    local -a zsh_files
    local file

    # Find .zsh files to compile
    zsh_files=($plugin_path/*.zsh(N) $plugin_path/**/*.plugin.zsh(N))

    # Compile each file individually using shared cache function
    for file in $zsh_files; do
        zdot_cache_compile_file "$file" 2>/dev/null || true
    done

    # Also compile any extra files registered via zdot_plugin_compile_extra
    for file in ${=_ZDOT_PLUGIN_COMPILE_EXTRA[$spec]:-}; do
        [[ -f "$file" ]] && zdot_cache_compile_file "$file" 2>/dev/null || true
    done
}

# Register extra files to be compiled alongside a plugin's auto-discovered .zsh files.
# Useful for files that live outside the plugin directory (e.g. nvm.sh, theme files).
#
# Usage: zdot_plugin_compile_extra <spec> <file> [<file> ...]
#
# Example:
#   zdot_plugin_compile_extra "ohmyzsh/ohmyzsh" "$NVM_DIR/nvm.sh"
zdot_plugin_compile_extra() {
    local spec=$1; shift
    local file
    for file in "$@"; do
        _ZDOT_PLUGIN_COMPILE_EXTRA[$spec]+="${_ZDOT_PLUGIN_COMPILE_EXTRA[$spec]:+ }$file"
    done
}

# Compile all declared plugins
zdot_compile_plugins() {
    local spec
    for spec in $_ZDOT_PLUGINS_ORDER; do
        zdot_plugin_compile "$spec"
    done
}

# Load all normal-kind plugins in declaration order
zdot_load_all_plugins() {
    local spec kind
    for spec in $_ZDOT_PLUGINS_ORDER; do
        kind=${_ZDOT_PLUGINS[$spec]}
        [[ $kind != normal ]] && continue
        zdot_load_plugin "$spec"
    done
}

# Load deferred plugins using zdot_defer wrapper
zdot_load_deferred_plugins() {
    # Sentinel: record that zdot_load_deferred_plugins fired and at what queue depth
    _zdot_defer_record \
        "--- zdot_load_deferred_plugins fired (queue depth: $_ZDOT_DEFER_COUNTER) ---" \
        "0" "__sentinel__"

    # Load deferred plugins - zdot_defer wrapper handles defer vs immediate
    local spec kind
    for spec in $_ZDOT_PLUGINS_ORDER; do
        kind=${_ZDOT_PLUGINS[$spec]}
        [[ $kind != defer ]] && continue

        # Use cached path (populated by zdot_plugin_clone / sentinel fast-path);
        # fall back to computing it inline without a subshell for user/repo specs.
        local plugin_path=${_ZDOT_PLUGINS_PATH[$spec]:-${_ZDOT_PLUGINS_CACHE}/${spec}}

        # Glob into an array — no ls subprocess, no head subprocess
        local -a _plugin_files=( $plugin_path/*.plugin.zsh(N) )
        local plugin_file=${_plugin_files[1]}

        [[ -z "$plugin_file" ]] && continue

        # Add to fpath if needed
        [[ -d "$plugin_path/functions" ]] && fpath+=( "$plugin_path" )

        # Load deferred - zdot_defer wrapper handles defer vs immediate;
        # suppress generic recording so we can record with spec label inline.
        _ZDOT_DEFER_SKIP_RECORD=1
        zdot_defer source "$plugin_file"
        _ZDOT_DEFER_SKIP_RECORD=0
        _zdot_defer_record "source $plugin_file" "0" "$spec"

        _ZDOT_PLUGINS_LOADED[$spec]=1
    done

    # Phase 1 of two-phase compinit: enqueue zdot_compinit_defer via zsh-defer
    # *after* all deferred plugin sources above.  zsh-defer executes callbacks
    # in FIFO order, so this runs only after every plugin has been sourced and
    # $fpath is fully populated.  zdot_compinit_defer simply sets
    # _ZDOT_FPATH_READY=1; the actual compinit runs in precmd context (phase 2)
    # via zdot_ensure_compinit_during_precmd, avoiding the ZLE-callback hang.
    _ZDOT_DEFER_SKIP_RECORD=1
    zdot_defer -q zdot_compinit_defer
    _ZDOT_DEFER_SKIP_RECORD=0
    _zdot_defer_record "zdot_compinit_defer" "0" ""
}

# ============================================================================
# Setup: Clone and load zsh-defer if enabled
# ============================================================================

_zdot_plugins_init

if zstyle -T ':zdot:plugins' defer; then
    # Register zsh-defer so it shows in plugin list
    zdot_use romkatv/zsh-defer
    
    # Clone zsh-defer using plugin mechanism
    zdot_plugin_clone romkatv/zsh-defer
    
    # Load zsh-defer
    zdot_load_plugin romkatv/zsh-defer
    
    # Define wrappers that use zsh-defer.
    # Both accept an optional -q (quiet) flag as the first argument.
    # -q suppresses precmd hooks (-m) and zle reset-prompt (-p) after the
    # deferred command runs, preventing prompts that embed a newline (e.g.
    # oh-my-posh with newline=true) from rendering a spurious blank line.
    # zsh-defer option syntax: '-' prefix removes a letter from opts (disables),
    # '+' prefix adds a letter (enables). Default opts already include 'm' and
    # 'p', so we need '-mp' to disable them, not '+mp' which is a no-op.
    # zdot_defer / zdot_defer_until — schedule a command to run after shell startup.
    #
    # Two implementations are compiled into one of two branches at load time,
    # selected by the 'defer' zstyle (`:zdot:plugins`):
    #
    # zsh-defer path (defer enabled):
    #   Wraps the `zsh-defer` utility.  The -q flag is passed by default, which
    #   disables zsh-defer's own -m (mark prompt) and -p (precmd) options.
    #   This prevents spurious blank lines with newline-style prompts: without -q,
    #   zsh-defer triggers `zle reset-prompt` after each deferred chunk, which
    #   inserts an extra newline when the prompt ends with a literal newline.
    #
    # Passthrough path (defer disabled):
    #   zdot_defer and zdot_defer_until become thin wrappers that execute their
    #   argument immediately (equivalent to `eval "$@"`).  Useful for testing or
    #   environments where deferred loading causes problems.
    #
    # Both paths call _zdot_defer_record to log the command into the display queue
    # (visible via `zdot show defer-queue`), UNLESS the caller has set
    # _ZDOT_DEFER_SKIP_RECORD=1 to suppress double-recording.
    zdot_defer() {
        local extra_opts='' _label=''
        [[ $1 == -q ]] && { extra_opts='-mp'; shift }
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        (( ! _ZDOT_DEFER_SKIP_RECORD )) && _zdot_defer_record "$*" "0" "" "$_label"
        zsh-defer ${extra_opts:+$extra_opts} "$@"
    }
    zdot_defer_until() {
        local extra_opts='' _label=''
        [[ $1 == -q ]] && { extra_opts='-mp'; shift }
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        local delay=$1; shift
        (( ! _ZDOT_DEFER_SKIP_RECORD )) && _zdot_defer_record "$*" "$delay" "" "$_label"
        zsh-defer ${extra_opts:+$extra_opts} -t "$delay" "$@"
    }
else
    # Define passthrough wrappers - run immediately.
    # -q is accepted for API compatibility but is a no-op here (no ZLE).
    zdot_defer() {
        local _label=''
        [[ $1 == -q ]] && shift
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        (( ! _ZDOT_DEFER_SKIP_RECORD )) && _zdot_defer_record "$*" "0" "" "$_label"
        "$@"
    }
    zdot_defer_until() {
        local _label=''
        [[ $1 == -q ]] && shift
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        local delay=$1; shift
        (( ! _ZDOT_DEFER_SKIP_RECORD )) && _zdot_defer_record "$*" "$delay" "" "$_label"
        "$@"
    }
fi

# ============================================================================
# Hook Registration
# ============================================================================

# This hook clones all declared plugins (but doesn't load them)
zdot_hook_register zdot_plugins_clone_all interactive noninteractive \
    --requires plugins-declared \
    --provides plugins-cloned
