#!/usr/bin/env zsh
# core/plugins: Lightweight plugin manager
# Declares plugins with zdot_use_plugin, loads on-demand with zdot_load_plugin

# ============================================================================
# Global State
# ============================================================================

typeset -ga _ZDOT_PLUGINS_ORDER         # Ordered list of plugin specs
typeset -gA _ZDOT_PLUGINS               # plugin spec -> kind (normal/defer/fpath/path)
typeset -gA _ZDOT_PLUGINS_LOADED        # plugin spec -> 1 (already loaded)
typeset -gA _ZDOT_PLUGIN_COMPILE_EXTRA  # plugin spec -> space-separated list of extra files to compile
typeset -gA _ZDOT_PLUGINS_VERSION       # plugin spec -> version/rev (optional)
typeset -gA _ZDOT_PLUGINS_PATH          # plugin spec -> filesystem path (populated at clone time)
typeset -gA _ZDOT_PLUGINS_FILE          # plugin spec -> *.plugin.zsh path (populated at load time)
typeset -g  _ZDOT_PLUGINS_CACHE         # cache directory
typeset -g  _ZDOT_PLUGINS_INITIALIZED=0
typeset -ga _ZDOT_BUNDLE_HANDLERS       # Ordered list of registered bundle handler names
typeset -ga _ZDOT_BUNDLE_REPOS          # Repos cloned as bundle dependencies (not user plugins)
typeset -gA _ZDOT_BUNDLE_INIT_FN        # bundle name -> init function name
typeset -gA _ZDOT_BUNDLE_PROVIDES       # bundle name -> phase token published after bundle init
typeset -ga _ZDOT_DEFER_CMDS            # [N] = command string submitted
typeset -ga _ZDOT_DEFER_HOOKS           # [N] = hook_func that submitted it (or "?" if outside hook)
typeset -ga _ZDOT_DEFER_DELAYS          # [N] = delay in seconds (0 if none)
typeset -ga _ZDOT_DEFER_SPECS           # [N] = human-readable spec name (plugins), "__sentinel__", or ""
typeset -ga _ZDOT_DEFER_LABELS          # [N] = explicit --label override (or "" if none)
typeset -g  _ZDOT_DEFER_COUNTER=0

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
        zdot_report "Defer Order Constraints:"
        zdot_info ""
        local _pi=1
        while [[ $_pi -lt ${#_ZDOT_DEFER_ORDER_PAIRS[@]} ]]; do
            local _fn="${_ZDOT_DEFER_ORDER_PAIRS[$_pi]}"
            local _tn="${_ZDOT_DEFER_ORDER_PAIRS[$(( _pi + 1 ))]}"
            (( _pi += 2 ))
            zdot_info "  %F{cyan}${_fn}%f → %F{cyan}${_tn}%f"
        done
        zdot_info ""
    fi
}

# Set _name_mark and _deferred_mark for a given hook_id/func pair.
# Usage: _zdot_hook_display_marks <hook_id> <func>
# Sets: _name_mark, _deferred_mark, _noquiet_mark (in caller's scope, no local)
_zdot_hook_display_marks() {
    local _hname="${_ZDOT_HOOK_NAMES[$1]:-$2}"
    _name_mark=""
    [[ "$_hname" != "$2" ]] && _name_mark=" %F{blue}[name: $_hname]%f"
    _deferred_mark=""
    [[ ${_ZDOT_DEFERRED_HOOKS[(Ie)$1]} -gt 0 ]] && _deferred_mark=" %F{magenta}[deferred]%f"
    _noquiet_mark=""
    local _defer_arg="${_ZDOT_HOOK_DEFER_ARGS[$1]:-}"
    if [[ -n "$_defer_arg" ]]; then
        local _flag_label="${_ZDOT_DEFER_FLAG_NAMES[$_defer_arg]:-$_defer_arg}"
        _noquiet_mark=" %F{yellow}[${_flag_label}]%f"
    fi
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
    [[ $_rd -eq 1 ]] && defer_mark=" %F{magenta}[ran deferred]%f"
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
# Usage: zdot_register_bundle <name>
zdot_register_bundle() {
    local name=$1
    [[ -z "$name" ]] && return 1
    shift

    # Parse optional flags: --init-fn <fn>  --provides <phase>
    local init_fn='' provides_phase=''
    while [[ $# -gt 0 ]]; do
        case $1 in
            --init-fn)  init_fn=$2;         shift 2 ;;
            --provides) provides_phase=$2;  shift 2 ;;
            *) zdot_error "zdot_register_bundle: unknown option: $1"; return 1 ;;
        esac
    done

    # Avoid duplicates
    local h
    for h in $_ZDOT_BUNDLE_HANDLERS; do
        [[ $h == $name ]] && return 0
    done
    _ZDOT_BUNDLE_HANDLERS+=( "$name" )

    [[ -n "$init_fn" ]]        && _ZDOT_BUNDLE_INIT_FN[$name]=$init_fn
    [[ -n "$provides_phase" ]] && _ZDOT_BUNDLE_PROVIDES[$name]=$provides_phase
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
# Public API: zdot_use_plugin
# ============================================================================

# Declare a plugin and register a load hook.
#
# New forms (preferred):
#   zdot_use_plugin <spec> hook  [--name <n>] [--provides <p>] [--config <fn>] [--context <c>]
#                                [--group <g>] [--requires-group <g>] [--provides-group <g>]
#   zdot_use_plugin <spec> defer [--name <n>] [--provides <p>] [--config <fn>] [--context <c>]
#                                [--requires <r>]
#                                [--group <g>] [--requires-group <g>] [--provides-group <g>]
#
# Legacy forms (still accepted):
#   zdot_use_plugin <spec>              # kind=normal — record for cloning only
#   zdot_use_plugin <spec> normal|defer|fpath|path
zdot_use_plugin() {
    local spec=$1
    if [[ -z "$spec" ]]; then
        zdot_error "zdot_use_plugin: plugin spec required"
        return 1
    fi
    shift

    # ── Determine subcommand ────────────────────────────────────────────────
    local subcommand=''
    case ${1:-} in
        hook|defer|defer-prompt) subcommand=$1; shift ;;
        # Legacy positional kind argument
        normal|defer|fpath|path) subcommand=_legacy_$1; shift ;;
        '') subcommand=_legacy_normal ;;
        *) zdot_error "zdot_use_plugin: unknown subcommand: $1"; return 1 ;;
    esac

    # ── Parse version from spec (user/repo@v1.0.0) ──────────────────────────
    local version=''
    if [[ $spec == *@* ]]; then
        version=${spec##*@}
        spec=${spec%@*}
    fi
    [[ -n "$version" ]] && _ZDOT_PLUGINS_VERSION[$spec]=$version

    # ── Legacy path: just record the spec ───────────────────────────────────
    if [[ $subcommand == _legacy_* ]]; then
        local kind=${subcommand#_legacy_}
        if [[ -z "${_ZDOT_PLUGINS[$spec]}" ]]; then
            _ZDOT_PLUGINS_ORDER+=$spec
        fi
        _ZDOT_PLUGINS[$spec]=$kind
        return 0
    fi

    # ── New hook / defer path ───────────────────────────────────────────────
    # Parse options
    local opt_name='' opt_provides='' opt_config='' opt_context=''
    local opt_requires='' opt_requires_group='' opt_provides_group=''
    local -a opt_groups=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)           opt_name=$2;           shift 2 ;;
            --provides)       opt_provides=$2;        shift 2 ;;
            --config)         opt_config=$2;          shift 2 ;;
            --context)        opt_context=$2;         shift 2 ;;
            --requires)
                [[ $subcommand == hook ]] && {
                    zdot_error "zdot_use_plugin: --requires is only valid with defer"
                    return 1
                }
                opt_requires=$2; shift 2 ;;
            --group)          opt_groups+=("$2");    shift 2 ;;
            --requires-group) opt_requires_group=$2;  shift 2 ;;
            --provides-group) opt_provides_group=$2;  shift 2 ;;
            *) zdot_error "zdot_use_plugin: unknown option: $1"; return 1 ;;
        esac
    done

    # Derive a safe function-name segment from spec (replace / : @ with _)
    local safe_spec=${spec//[\/\:\@]/_}
    local loader_name=_zdot_autoload_${opt_name:-$safe_spec}

    # Record spec for cloning (legacy map doubles as the clone list)
    if [[ -z "${_ZDOT_PLUGINS[$spec]}" ]]; then
        _ZDOT_PLUGINS_ORDER+=$spec
    fi
    local kind=normal
    [[ $subcommand == defer || $subcommand == defer-prompt ]] && kind=defer
    _ZDOT_PLUGINS[$spec]=$kind

    # Auto-inject --requires from bundle's provides phase if not already set
    if [[ ($subcommand == defer || $subcommand == defer-prompt) && -z "$opt_requires" ]]; then
        local handler
        if _zdot_bundle_handler_for "$spec"; then
            handler=$REPLY
            local bundle_provides=${_ZDOT_BUNDLE_PROVIDES[$handler]:-}
            [[ -n "$bundle_provides" ]] && opt_requires=$bundle_provides
        fi
    fi

    # Build the private loader function
    local _def
    IFS= read -r -d '' _def << EOD
${loader_name}() {
    local _spec=${(q)spec}
    # Optional config callback — resolve dir only when a callback is set
    ${opt_config:+zdot_plugin_path "\$_spec" && ${opt_config} "\$REPLY" "\$_spec"}
    zdot_load_plugin "\$_spec"
}
EOD
    eval "$_def"

    # Build zdot_register_hook argument list
    local -a hook_args=( "$loader_name" interactive noninteractive )
    [[ -n "$opt_provides" ]]       && hook_args+=( --provides        "$opt_provides" )
    [[ -n "$opt_context" ]]        && hook_args+=( --context         "$opt_context" )
    local _og
    for _og in "${opt_groups[@]}"; do
        hook_args+=( --group "$_og" )
    done
    [[ -n "$opt_requires_group" ]] && hook_args+=( --requires-group  "$opt_requires_group" )
    [[ -n "$opt_provides_group" ]] && hook_args+=( --provides-group  "$opt_provides_group" )
    if [[ $subcommand == defer || $subcommand == defer-prompt ]]; then
        [[ $subcommand == defer ]]         && hook_args+=( --deferred )
        [[ $subcommand == defer-prompt ]] && hook_args+=( --defer-prompt )
        [[ -n "$opt_requires" ]] && hook_args+=( --requires "$opt_requires" )
    fi

    zdot_register_hook "${hook_args[@]}"
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
# Module Definition Sugar
# ============================================================================

# zdot_simple_hook <name> [flags...]
#
# Sugar for the most common single-hook module pattern. Auto-derives:
#   fn       = _<name>_init         (must already exist)
#   requires = xdg-configured       (override with --requires, clear with --no-requires)
#   provides = <name>-configured    (override with --provides)
#   contexts = interactive noninteractive (override with --context)
#
# Supported flags:
#   --provides <phase>            Override the auto-derived provides token
#   --requires <phase...>         Override the default requires (xdg-configured)
#   --no-requires                 Clear all auto-derived requires
#   --context <ctx...>            Override contexts (default: interactive noninteractive)
#   --fn <name>                   Override the auto-derived function name
#
# All other flags (--provides-tool, --requires-tool, --optional, --name,
# --group, --deferred, etc.) are passed through to zdot_register_hook.
zdot_simple_hook() {
    local name="$1"; shift
    local fn="_${name}_init"
    local provides="${name}-configured"
    local -a requires=(xdg-configured)
    local -a contexts=(interactive noninteractive)
    local no_requires=false
    local -a passthrough=()

    while (( $# )); do
        case "$1" in
            --provides)
                provides="$2"; shift 2 ;;
            --requires)
                requires=()
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    requires+=("$1"); shift
                done
                ;;
            --no-requires)
                no_requires=true; shift ;;
            --context)
                contexts=()
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    contexts+=("$1"); shift
                done
                ;;
            --fn)
                fn="$2"; shift 2 ;;
            *)
                passthrough+=("$1"); shift ;;
        esac
    done

    local -a req_args=()
    if ! $no_requires; then
        local _r
        for _r in "${requires[@]}"; do
            req_args+=(--requires "$_r")
        done
    fi

    zdot_register_hook "$fn" "${contexts[@]}" \
        "${req_args[@]}" \
        --provides "$provides" \
        "${passthrough[@]}"
}

# ============================================================================

# zdot_define_module <basename> [flags...]
#
# Declarative module definition that auto-derives hook names and phase tokens
# from <basename>, while accepting explicit function names for each lifecycle
# phase.
#
# Phase flags (each takes a function name):
#   --configure <fn>              Configure hook (eager, provides <basename>-configured)
#   --load <fn>                   Custom loader  (eager, provides <basename>-loaded)
#   --load-plugins <specs...>     Auto-generate loader from plugin specs
#   --post-init <fn>              Post-init hook (deferred interactive, provides <basename>-post-configured)
#   --interactive-init <fn>       Interactive init (deferred, provides <basename>-interactive-ready)
#   --noninteractive-init <fn>    Non-interactive init (eager, provides <basename>-noninteractive-ready)
#
# Modifier flags:
#   --context <ctx...>            Default contexts (default: interactive noninteractive)
#   --provides-tool <tool>        Tool provided by the load phase
#   --requires-tool <tool>        Tool required by the load phase
#   --requires <phase...>         Extra requirements for the load phase
#   --auto-bundle                 Auto-detect bundle group/requires from plugin specs
#   --group <name>                Explicit group for the load phase
#   --configure-context <ctx...>  Override configure context (default: --context value)
#   --load-context <ctx...>       Override load context (default: --context value)
#   --post-init-requires <p...>   Override post-init requires (default: <basename>-loaded)
#   --post-init-context <ctx...>  Override post-init context (default: interactive)
#
# Auto-derived names (from <basename>):
#   Hook names:   <basename>-configure, <basename>-load, <basename>-post-init, ...
#   Phase tokens: <basename>-configured, <basename>-loaded, <basename>-post-configured, ...
#
zdot_define_module() {
    local basename="$1"
    [[ -z "$basename" ]] && { zdot_error "zdot_define_module: basename required"; return 1; }
    shift

    # --- Parse flags ---
    local configure_fn="" load_fn="" post_init_fn=""
    local interactive_init_fn="" noninteractive_init_fn=""
    local -a load_plugins=()
    local -a provides_tools=() requires_tools=()
    local -a extra_requires=() extra_groups=()
    local -a configure_contexts=() load_contexts=()
    local -a post_init_requires=() post_init_contexts=()
    local auto_bundle=0
    local -a contexts=(interactive noninteractive)

    while (( $# )); do
        case "$1" in
            --configure)
                configure_fn="$2"; shift 2 ;;
            --load)
                load_fn="$2"; shift 2 ;;
            --load-plugins)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    load_plugins+=("$1"); shift
                done
                ;;
            --post-init)
                post_init_fn="$2"; shift 2 ;;
            --interactive-init)
                interactive_init_fn="$2"; shift 2 ;;
            --noninteractive-init)
                noninteractive_init_fn="$2"; shift 2 ;;
            --provides-tool)
                provides_tools+=("$2"); shift 2 ;;
            --requires-tool)
                requires_tools+=("$2"); shift 2 ;;
            --requires)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    extra_requires+=("$1"); shift
                done
                ;;
            --auto-bundle)
                auto_bundle=1; shift ;;
            --group)
                extra_groups+=("$2"); shift 2 ;;
            --configure-context)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    configure_contexts+=("$1"); shift
                done
                ;;
            --load-context)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    load_contexts+=("$1"); shift
                done
                ;;
            --post-init-requires)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    post_init_requires+=("$1"); shift
                done
                ;;
            --post-init-context)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    post_init_contexts+=("$1"); shift
                done
                ;;
            --context)
                contexts=()
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    contexts+=("$1"); shift
                done
                ;;
            *)
                zdot_warn "zdot_define_module: unknown flag: $1"; shift ;;
        esac
    done

    # Validate: --load and --load-plugins are mutually exclusive
    if [[ -n "$load_fn" ]] && (( ${#load_plugins} )); then
        zdot_error "zdot_define_module: --load and --load-plugins are mutually exclusive"
        return 1
    fi

    # --- Configure phase ---
    if [[ -n "$configure_fn" ]]; then
        local -a cfg_ctx=("${contexts[@]}")
        if (( ${#configure_contexts} )); then
            cfg_ctx=("${configure_contexts[@]}")
        fi
        zdot_register_hook "$configure_fn" "${cfg_ctx[@]}" \
            --name "${basename}-configure" \
            --requires xdg-configured \
            --provides "${basename}-configured"
    fi

    # --- Load phase ---
    local load_provides="${basename}-loaded"
    local -a load_hook_args=()

    load_hook_args+=(--name "${basename}-load")
    load_hook_args+=(--provides "$load_provides")

    # If configure exists, load depends on it
    if [[ -n "$configure_fn" ]]; then
        load_hook_args+=(--requires "${basename}-configured")
    fi

    # Tool provides/requires
    local t
    for t in "${provides_tools[@]}"; do
        load_hook_args+=(--provides-tool "$t")
    done
    for t in "${requires_tools[@]}"; do
        load_hook_args+=(--requires-tool "$t")
    done

    # Extra requires/groups from flags
    local r g
    for r in "${extra_requires[@]}"; do
        load_hook_args+=(--requires "$r")
    done
    for g in "${extra_groups[@]}"; do
        load_hook_args+=(--group "$g")
    done

    # Resolve load context: --load-context overrides --context
    local -a ld_ctx=("${contexts[@]}")
    if (( ${#load_contexts} )); then
        ld_ctx=("${load_contexts[@]}")
    fi

    if [[ -n "$load_fn" ]]; then
        # Explicit load function
        zdot_register_hook "$load_fn" "${ld_ctx[@]}" "${load_hook_args[@]}"

    elif (( ${#load_plugins} )); then
        # Auto-generate loader from plugin specs

        # Declare plugins for cloning
        local spec
        for spec in "${load_plugins[@]}"; do
            zdot_use_plugin "$spec"
        done

        # Auto-bundle: detect bundle handlers and inject their group/requires
        if (( auto_bundle )); then
            local -A _dm_seen_bundles=()
            local _dm_handler _dm_spec
            for _dm_spec in "${load_plugins[@]}"; do
                if _zdot_bundle_handler_for "$_dm_spec"; then
                    _dm_handler="$REPLY"
                    if (( ! ${+_dm_seen_bundles[$_dm_handler]} )); then
                        _dm_seen_bundles[$_dm_handler]=1
                        local _dm_bp="${_ZDOT_BUNDLE_PROVIDES[$_dm_handler]}"
                        if [[ -n "$_dm_bp" ]]; then
                            load_hook_args+=(--requires "$_dm_bp")
                        fi
                        load_hook_args+=(--group "${_dm_handler}-plugins")
                    fi
                fi
            done
            load_hook_args+=(--requires plugins-cloned)
        fi

        # Generate loader function
        local loader_name="_zdot_module_${basename}_load"
        local loader_body=""
        for spec in "${load_plugins[@]}"; do
            loader_body+="    zdot_load_plugin ${(q)spec}"$'\n'
        done
        eval "${loader_name}() {"$'\n'"${loader_body}}"

        zdot_register_hook "$loader_name" "${ld_ctx[@]}" "${load_hook_args[@]}"
    fi

    # --- Determine whether a load phase was actually registered ---
    local has_load=0
    if [[ -n "$load_fn" ]] || (( ${#load_plugins} )); then
        has_load=1
    fi

    # --- Post-init phase (deferred) ---
    if [[ -n "$post_init_fn" ]]; then
        # Determine context: --post-init-context overrides, else default interactive
        local -a pi_ctx=(interactive)
        if (( ${#post_init_contexts} )); then
            pi_ctx=("${post_init_contexts[@]}")
        fi

        # Determine requires: --post-init-requires overrides, else auto-derive
        local -a pi_req_args=()
        if (( ${#post_init_requires} )); then
            local _pir
            for _pir in "${post_init_requires[@]}"; do
                pi_req_args+=(--requires "$_pir")
            done
        elif (( has_load )); then
            pi_req_args+=(--requires "$load_provides")
        fi

        zdot_register_hook "$post_init_fn" "${pi_ctx[@]}" \
            --name "${basename}-post-init" \
            --deferred \
            "${pi_req_args[@]}" \
            --provides "${basename}-post-configured"
    fi

    # --- Interactive init (deferred) ---
    if [[ -n "$interactive_init_fn" ]]; then
        local -a ii_req_args=()
        if (( has_load )); then
            ii_req_args+=(--requires "$load_provides")
        fi

        zdot_register_hook "$interactive_init_fn" interactive \
            --name "${basename}-interactive-init" \
            --deferred \
            "${ii_req_args[@]}" \
            --provides "${basename}-interactive-ready"
    fi

    # --- Noninteractive init (eager) ---
    if [[ -n "$noninteractive_init_fn" ]]; then
        local -a ni_req_args=()
        if (( has_load )); then
            ni_req_args+=(--requires "$load_provides")
        fi

        zdot_register_hook "$noninteractive_init_fn" noninteractive \
            --name "${basename}-noninteractive-init" \
            "${ni_req_args[@]}" \
            --provides "${basename}-noninteractive-ready"
    fi
}



# ============================================================================
# Initialization
# ============================================================================

# Clone all plugin repos synchronously and mark the plugins-cloned phase.
_zdot_init_clone() {
    zdot_plugins_clone_all
}
zdot_register_hook _zdot_init_clone interactive noninteractive \
    --name plugins-cloned-init \
    --provides plugins-cloned
typeset -g _ZDOT_INIT_CLONE_HOOK_ID=$REPLY

# Run each bundle's init function (registered via zdot_register_bundle --init).
_zdot_init_bundles() {
    local _bundle_name
    for _bundle_name in "${_ZDOT_BUNDLE_HANDLERS[@]}"; do
        local _init_fn="${_ZDOT_BUNDLE_INIT_FN[$_bundle_name]:-}"
        if [[ -n $_init_fn ]] && (( ${+functions[$_init_fn]} )); then
            "$_init_fn"
        fi
    done
}

# Resolve group annotations into concrete dependency edges by synthesising
# barrier hooks at resolve-time.
#
# For each group G (referenced by --group, --provides-group, or --requires-group):
#
#   1. Synthesise two no-op barrier hooks:
#        _zdot_group_begin_G  →  provides phase  _group_begin_G
#        _zdot_group_end_G    →  provides phase  _group_end_G
#      Both are given the union of all member contexts so they survive the DAG
#      context filter.
#
#   2. For every member M of group G:
#        • inject _group_begin_G into _ZDOT_HOOK_REQUIRES[M]   (M runs after begin)
#        • synthesise phase _group_member_G_<hid_m>, append to _ZDOT_HOOK_PROVIDES[M]
#        • inject _group_member_G_<hid_m> into _ZDOT_HOOK_REQUIRES of _zdot_group_end_G
#          (end runs only after every member has provided its member phase)
#
#   3. For every hook H with --requires-group G:
#        • inject _group_end_G into _ZDOT_HOOK_REQUIRES[H]
#
# All synthetic phases are registered into _ZDOT_PHASE_PROVIDERS_BY_CONTEXT for
# every context in the union so the DAG provider-check passes.
_zdot_init_resolve_groups() {
    local _grp _hid _ctx _member _phase _hid_begin _hid_end

    # ── Collect all group names ──────────────────────────────────────────────
    local -A _all_groups
    for _grp in "${(k)_ZDOT_GROUP_MEMBERS[@]}"; do
        _all_groups[$_grp]=1
    done
    for _hid in "${(k)_ZDOT_HOOKS[@]}"; do
        _grp="${_ZDOT_HOOK_REQUIRES_GROUP[$_hid]:-}"
        [[ -n $_grp ]] && _all_groups[$_grp]=1
    done

    # ── Process each group ───────────────────────────────────────────────────
    local -A _ctx_union
    for _grp in "${(k)_all_groups[@]}"; do

        # 'finally' members are dispatched directly by the deferred drain;
        # skip DAG barrier synthesis entirely for this group.
        [[ $_grp == finally ]] && continue

        # -- Compute union of member AND requiring-hook contexts -------------
        _ctx_union=()
        for _member in ${=_ZDOT_GROUP_MEMBERS[$_grp]:-}; do
            for _ctx in ${=_ZDOT_HOOK_CONTEXTS[$_member]:-}; do
                _ctx_union[$_ctx]=1
            done
        done
        # Always include contexts from hooks that require this group, so that
        # the synthetic barriers are visible to the DAG context filter even
        # when the requiring hook runs in a wider context than the members.
        for _hid in "${(k)_ZDOT_HOOKS[@]}"; do
            [[ "${_ZDOT_HOOK_REQUIRES_GROUP[$_hid]:-}" == "$_grp" ]] || continue
            for _ctx in ${=_ZDOT_HOOK_CONTEXTS[$_hid]:-}; do
                _ctx_union[$_ctx]=1
            done
        done
        local _ctx_list="${(j: :)${(k)_ctx_union}}"

        # -- Allocate barrier hook IDs ---------------------------------------
        (( _ZDOT_HOOK_COUNTER++ ))
        _hid_begin="hook_${_ZDOT_HOOK_COUNTER}"
        (( _ZDOT_HOOK_COUNTER++ ))
        _hid_end="hook_${_ZDOT_HOOK_COUNTER}"

        local _fn_begin="_zdot_group_begin_${_grp}"
        local _fn_end="_zdot_group_end_${_grp}"
        local _phase_begin="_group_begin_${_grp}"
        local _phase_end="_group_end_${_grp}"

        # -- Define barrier shell functions (no-ops; ordering is DAG-enforced) -
        eval "${_fn_begin}() { return 0; }"
        eval "${_fn_end}() { return 0; }"

        # -- Register begin barrier ------------------------------------------
        _ZDOT_HOOKS[$_hid_begin]=$_fn_begin
        _ZDOT_HOOK_NAMES[$_hid_begin]="group-begin:${_grp}"
        _ZDOT_HOOK_BY_NAME["group-begin:${_grp}"]=$_hid_begin
        _ZDOT_HOOK_CONTEXTS[$_hid_begin]="$_ctx_list"
        _ZDOT_HOOK_REQUIRES[$_hid_begin]=""
        _ZDOT_HOOK_PROVIDES[$_hid_begin]="$_phase_begin"
        _ZDOT_HOOK_OPTIONAL[$_hid_begin]=1

        # -- Register end barrier --------------------------------------------
        _ZDOT_HOOKS[$_hid_end]=$_fn_end
        _ZDOT_HOOK_NAMES[$_hid_end]="group-end:${_grp}"
        _ZDOT_HOOK_BY_NAME["group-end:${_grp}"]=$_hid_end
        _ZDOT_HOOK_CONTEXTS[$_hid_end]="$_ctx_list"
        _ZDOT_HOOK_REQUIRES[$_hid_end]=""
        _ZDOT_HOOK_PROVIDES[$_hid_end]="$_phase_end"
        _ZDOT_HOOK_OPTIONAL[$_hid_end]=1

        # -- Register begin/end phases into _ZDOT_PHASE_PROVIDERS_BY_CONTEXT -
        for _ctx in ${(k)_ctx_union}; do
            _ZDOT_PHASE_PROVIDERS_BY_CONTEXT[${_ctx}:${_phase_begin}]=$_hid_begin
            _ZDOT_PHASE_PROVIDERS_BY_CONTEXT[${_ctx}:${_phase_end}]=$_hid_end
        done

        # -- Wire each member through the barriers ---------------------------
        for _member in ${=_ZDOT_GROUP_MEMBERS[$_grp]:-}; do
            # M must run after the begin barrier
            if [[ " ${_ZDOT_HOOK_REQUIRES[$_member]:-} " != *" ${_phase_begin} "* ]]; then
                _ZDOT_HOOK_REQUIRES[$_member]+="${_ZDOT_HOOK_REQUIRES[$_member]:+ }${_phase_begin}"
            fi

            # Synthesise per-member phase and register it
            local _phase_member="_group_member_${_grp}_${_member}"
            if [[ " ${_ZDOT_HOOK_PROVIDES[$_member]:-} " != *" ${_phase_member} "* ]]; then
                _ZDOT_HOOK_PROVIDES[$_member]+="${_ZDOT_HOOK_PROVIDES[$_member]:+ }${_phase_member}"
            fi
            for _ctx in ${(k)_ctx_union}; do
                _ZDOT_PHASE_PROVIDERS_BY_CONTEXT[${_ctx}:${_phase_member}]=$_member
            done

            # End barrier must run after this member's phase
            if [[ " ${_ZDOT_HOOK_REQUIRES[$_hid_end]:-} " != *" ${_phase_member} "* ]]; then
                _ZDOT_HOOK_REQUIRES[$_hid_end]+="${_ZDOT_HOOK_REQUIRES[$_hid_end]:+ }${_phase_member}"
            fi
        done

        # -- Wire requires-group hooks to run after the end barrier ----------
        for _hid in "${(k)_ZDOT_HOOKS[@]}"; do
            [[ "${_ZDOT_HOOK_REQUIRES_GROUP[$_hid]:-}" == "$_grp" ]] || continue
            if [[ " ${_ZDOT_HOOK_REQUIRES[$_hid]:-} " != *" ${_phase_end} "* ]]; then
                _ZDOT_HOOK_REQUIRES[$_hid]+="${_ZDOT_HOOK_REQUIRES[$_hid]:+ }${_phase_end}"
            fi
        done

    done
}

# Build the execution plan (cache-aware), fire all hooks, then compile to bytecode.
_zdot_init_plan_and_execute() {
    if ! load_cache; then
        zdot_build_execution_plan
        zdot_cache_save_plan
    fi
    zdot_execute_all

    # Compile all modules to bytecode for faster loading.
    # Must run after zdot_execute_all: plugin execution may generate new .zsh
    # files on disk (init scripts, lazy loaders, etc.) that don't exist until
    # sourcing completes. Compiling first would miss those files.
    zdot_cache_compile_all
}

# Single entry point: clone → bundle init → group resolution → plan → execute → compile.
zdot_init() {
    (( _ZDOT_INIT_DONE )) && return 0
    typeset -g _ZDOT_INIT_DONE=1
    _zdot_execute_hook "$_ZDOT_INIT_CLONE_HOOK_ID" "_zdot_init_clone"
    _zdot_init_bundles
    _zdot_init_resolve_groups
    _zdot_init_plan_and_execute
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

# ============================================================================
# Setup: Clone and load zsh-defer if enabled
# ============================================================================

_zdot_plugins_init

if zstyle -T ':zdot:plugins' defer; then
    # Register zsh-defer so it shows in plugin list
    zdot_use_plugin romkatv/zsh-defer
    
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
    # (visible via `zdot show defer-queue`).
    zdot_defer() {
        local -a extra_opts=()
        local _label=''
        [[ $1 == -q || $1 == --quiet ]] && { extra_opts+=(-m -p -s -z); shift }
        [[ $1 == -p || $1 == --prompt  ]] && { extra_opts+=(+p -s -z); shift }
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        _zdot_defer_record "$*" "0" "" "$_label"
        # zdot_info "running zsh-defer ${extra_opts[@]} $@"
        zsh-defer "${extra_opts[@]}" "$@"
    }
    zdot_defer_until() {
        local -a extra_opts=()
        local _label=''
        [[ $1 == -q || $1 == --quiet ]] && { extra_opts+=(-m -p -s -z); shift }
        [[ $1 == -p || $1 == --prompt  ]] && { extra_opts+=(+p -s -z); shift }
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        local delay=$1; shift
        _zdot_defer_record "$*" "$delay" "" "$_label"
        # zdot_info "running zsh-defer ${extra_opts[@]} $@"
        zsh-defer "${extra_opts[@]}" -t "$delay" "$@"
    }
else
    # Define passthrough wrappers - run immediately.
    # -q and -p are accepted for API compatibility but are no-ops here (no ZLE).
    zdot_defer() {
        local _label=''
        [[ $1 == -q || $1 == --quiet || $1 == -p || $1 == --prompt ]] && shift
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        _zdot_defer_record "$*" "0" "" "$_label"
        "$@"
    }
    zdot_defer_until() {
        local _label=''
        [[ $1 == -q || $1 == --quiet || $1 == -p || $1 == --prompt ]] && shift
        [[ $1 == --label ]] && { _label="$2"; shift 2 }
        local delay=$1; shift
        _zdot_defer_record "$*" "$delay" "" "$_label"
        "$@"
    }
fi

