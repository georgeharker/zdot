#!/usr/bin/env zsh
# core/plugins: Lightweight plugin manager
# Declares plugins with zdot_use, loads on-demand with zdot_load_plugin

# ============================================================================
# Global State
# ============================================================================

typeset -ga _ZDOT_PLUGINS_ORDER   # Ordered list of plugin specs
typeset -gA _ZDOT_PLUGINS        # plugin spec -> kind (normal/defer/fpath/path)
typeset -gA _ZDOT_PLUGINS_LOADED # plugin spec -> 1 (already loaded)
typeset -gA _ZDOT_PLUGINS_VERSION # plugin spec -> version/rev (optional)
typeset -gA _ZDOT_PLUGINS_PATH   # plugin spec -> filesystem path (populated at clone time)
typeset -gA _ZDOT_PLUGINS_FILE   # plugin spec -> *.plugin.zsh path (populated at load time)
typeset -g  _ZDOT_PLUGINS_CACHE  # cache directory
typeset -g  _ZDOT_PLUGINS_INITIALIZED=0
typeset -ga _ZDOT_BUNDLE_HANDLERS # Ordered list of registered bundle handler names

# ============================================================================
# Plugin Rev Stamp
# ============================================================================

typeset -g _ZDOT_PLUGINS_REV_STAMP

_zdot_plugins_rev_stamp_init() {
    [[ -n "$_ZDOT_PLUGINS_REV_STAMP" ]] && return 0
    local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot"
    _ZDOT_PLUGINS_REV_STAMP="${cache_dir}/plugin-revs.zsh"
}

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
# Prints the handler name; returns 1 if none found.
_zdot_bundle_handler_for() {
    local spec=$1
    local name
    for name in $_ZDOT_BUNDLE_HANDLERS; do
        if zdot_bundle_${name}_match "$spec" 2>/dev/null; then
            print "$name"
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

# ============================================================================
# Path Resolution
# ============================================================================

zdot_plugin_path() {
    local spec=$1
    local cache=${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugins}

    # Delegate to bundle handler if one is registered for this spec
    local handler
    handler=$(_zdot_bundle_handler_for "$spec") && {
        zdot_bundle_${handler}_path "$spec"
        return
    }

    print "$cache/$spec"
}

# ============================================================================
# Plugin Cloning
# ============================================================================

zdot_plugin_clone() {
    local spec=$1
    local cache=${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugins}

    # Delegate to bundle handler if one is registered for this spec
    local handler
    handler=$(_zdot_bundle_handler_for "$spec") && {
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

# Clone all declared plugins
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
    handler=$(_zdot_bundle_handler_for "$spec") && {
        zdot_bundle_${handler}_load "$spec"
        _ZDOT_PLUGINS_LOADED[$spec]=1
        return 0
    }

    local plugin_path=$(zdot_plugin_path $spec)
    
    local plugin_file
    local kind=${_ZDOT_PLUGINS[$spec]:-normal}
    
    # Find plugin file
    plugin_file=$(ls $plugin_path/*.plugin.zsh(N) 2>/dev/null | head -1)
    
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
    
    # Optionally compile plugin to .zwc for faster loading
    local compile_plugins
    zstyle -b ':zdot:plugins' compile compile_plugins || compile_plugins=false
    if [[ "$compile_plugins" == true ]]; then
        zdot_plugin_compile "$spec"
    fi
    
    return 0
}

# Compile a plugin's .zsh files to .zwc bytecode
# Uses zdot_cache_compile_file for each file
zdot_plugin_compile() {
    local spec=$1
    local plugin_path=$(zdot_plugin_path $spec)
    
    [[ -d "$plugin_path" ]] || return 1
    
    local -a zsh_files
    
    # Find .zsh files to compile
    zsh_files=($plugin_path/*.zsh(N) $plugin_path/**/*.plugin.zsh(N))
    
    [[ ${#zsh_files[@]} -eq 0 ]] && return 0
    
    # Compile each file individually using shared cache function
    local file
    for file in $zsh_files; do
        zdot_cache_compile_file "$file" 2>/dev/null || true
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

        # Load deferred - zdot_defer wrapper handles defer vs immediate
        zdot_defer source "$plugin_file"
        _ZDOT_PLUGINS_LOADED[$spec]=1
    done

    # Enqueue compinit after all deferred plugin sources so fpath is fully
    # populated (deferred plugins add completion dirs during their source).
    # In the non-defer passthrough path zdot_defer calls zdot_compinit_defer
    # directly; its [[ -o interactive ]] guard handles non-interactive shells.
    zdot_defer zdot_compinit_defer
}

# ============================================================================
# Setup: Clone and load zsh-defer if enabled
# ============================================================================

_zdot_plugins_init

local _zdot_defer_enabled
zstyle -b ':zdot:plugins' defer _zdot_defer_enabled || _zdot_defer_enabled=true

if [[ "$_zdot_defer_enabled" == true ]]; then
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
    zdot_defer() {
        local extra_opts=''
        [[ $1 == -q ]] && { extra_opts='-mp'; shift }
        zsh-defer ${extra_opts:+$extra_opts} "$@"
    }
    zdot_defer_until() {
        local extra_opts=''
        [[ $1 == -q ]] && { extra_opts='-mp'; shift }
        local delay=$1; shift
        zsh-defer ${extra_opts:+$extra_opts} -t "$delay" "$@"
    }
else
    # Define passthrough wrappers - run immediately.
    # -q is accepted for API compatibility but is a no-op here (no ZLE).
    zdot_defer() { [[ $1 == -q ]] && shift; "$@" }
    zdot_defer_until() { [[ $1 == -q ]] && shift; local delay=$1; shift; "$@"; }
fi

# ============================================================================
# Hook Registration
# ============================================================================

# This hook clones all declared plugins (but doesn't load them)
zdot_hook_register zdot_plugins_clone_all interactive noninteractive \
    --requires plugins-declared \
    --provides plugins-cloned
