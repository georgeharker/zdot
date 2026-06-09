#!/usr/bin/env zsh
# zsh-base/modules: Module discovery and loading system
# Provides module lifecycle management

# ============================================================================
# Module Search Path
# ============================================================================

# Build (once) the ordered list of directories to search for modules.
# Order:
#   1. User-supplied paths from zstyle ':zdot:modules' search-path (tilde-expanded)
#   2. XDG default user module dir: ${XDG_CONFIG_HOME}/zdot-modules (if it exists)
#   3. Built-in modules dir: _ZDOT_MODULE_DIR (always included)
# Non-existent directories from the zstyle list are silently skipped.
# Cached in _ZDOT_MODULE_SEARCH_PATH after the first call.
_zdot_build_module_search_path() {
    [[ ${#_ZDOT_MODULE_SEARCH_PATH} -gt 0 ]] && return 0
    local -a extra_paths
    zstyle -a ':zdot:modules' search-path extra_paths
    local p
    for p in "${extra_paths[@]}"; do
        local _expanded="${~p}"
        [[ -d "$_expanded" ]] && _ZDOT_MODULE_SEARCH_PATH+=("$_expanded")
    done
    # XDG default: include automatically if it exists, no zstyle needed
    local _xdg_default="${XDG_CONFIG_HOME:-${HOME}/.config}/zdot-modules"
    if [[ -d "$_xdg_default" ]]; then
        # Only add if not already present via zstyle
        [[ " ${_ZDOT_MODULE_SEARCH_PATH[*]} " != *" ${_xdg_default} "* ]] && \
            _ZDOT_MODULE_SEARCH_PATH+=("$_xdg_default")
    fi
    _ZDOT_MODULE_SEARCH_PATH+=("${_ZDOT_MODULE_DIR}")
}

# ============================================================================
# Module Loading
# ============================================================================

# Get the directory of the calling module
# Usage: zdot_module_dir; local mydir="$REPLY"
# Must be called from within a module file
# Uses _ZDOT_CURRENT_MODULE_DIR if set (during module loading)
zdot_module_dir() {
    if [[ -n "$_ZDOT_CURRENT_MODULE_DIR" ]]; then
        REPLY="$_ZDOT_CURRENT_MODULE_DIR"
    else
        # Fallback: Use ${(%):-%x} to get the path of the sourced file
        local module_file="${${(%):-%x}:A}"
        REPLY="${module_file:h}"
    fi
}

# Find the first occurrence of a module across the search path.
# Usage: zdot_module_path <module-name>; local path="$REPLY"
# Sets REPLY to the full path of <name>/<name>.zsh, or returns 1 if not found.
zdot_module_path() {
    local module="$1"
    if [[ -z "$module" ]]; then
        zdot_error "zdot_module_path: module name required"
        return 1
    fi
    _zdot_build_module_search_path
    local dir
    for dir in "${_ZDOT_MODULE_SEARCH_PATH[@]}"; do
        local candidate="${dir}/${module}/${module}.zsh"
        if [[ -f "$candidate" ]]; then
            REPLY="$candidate"
            return 0
        fi
    done
    return 1
}

# Internal: load a module from an explicit file path.
# Handles dedup, existence check, drains any registered before-module callbacks
# (see zdot_before_module), sources the file (cache-aware), and marks
# _ZDOT_MODULES_LOADED / _ZDOT_MODULE_SOURCE_DIR.
# Usage: _zdot_load_module_file <module-name> <module-file>
_zdot_load_module_file() {
    local module="$1" module_file="$2"
    [[ -n "${_ZDOT_MODULES_LOADED[$module]}" ]] && return 0
    if [[ ! -f "$module_file" ]]; then
        zdot_error "_zdot_load_module_file: module file not found: $module_file"
        return 1
    fi
    # Drain before-module callbacks. These run synchronously before sourcing
    # so they can set zstyles or other shell state that the module reads at
    # parse time.
    if [[ -n "${_ZDOT_BEFORE_MODULE[$module]:-}" ]]; then
        local _bm_fn
        for _bm_fn in ${=_ZDOT_BEFORE_MODULE[$module]}; do
            if (( ${+functions[$_bm_fn]} )); then
                zdot_verbose "zdot_before_module: running '$_bm_fn' for module '$module'"
                "$_bm_fn"
            else
                zdot_warn "zdot_before_module: function '$_bm_fn' not defined; skipping for module '$module'"
            fi
        done
    fi
    _zdot_source_module "$module" "$module_file"
    _ZDOT_MODULES_LOADED[$module]=1
    _ZDOT_MODULE_SOURCE_DIR[$module]="${module_file:h}"
}

# Register a callback to run synchronously before a module is sourced. The
# callback is invoked by _zdot_load_module_file immediately before the module
# file is sourced, so it can set zstyles or other shell state that the module
# reads at parse time.
#
# Usage:
#   zdot_before_module <module> --fn  <function-name>
#   zdot_before_module <module> --cmd <command> [args...]
#
# --fn registers an existing function.
# --cmd takes the rest of its arguments as a command + args; an anonymous
# function is generated to run it. Exactly one of --fn / --cmd must be given.
#
# Multiple callbacks can be registered per module; they run in registration
# order. The --fn form is deduplicated by function name (re-registering the
# same fn for the same module is a no-op). The --cmd form is NOT deduplicated
# — each call generates a distinct anonymous function.
#
# Registering after the module has already been loaded is a programming error;
# it emits a warning and the callback will not run.
#
# Note: for one-off zstyles, setting them directly in .zshrc before
# zdot_load_module is lighter and has no API surface:
#
#   zstyle ':zdot:brew' verify-tools op fd ripgrep
#   zdot_load_module brew
#
# Reach for zdot_before_module when you want to group multiple settings per
# module, when parse-time setup has conditional logic, or when per-module
# config files should self-register without strict source-order requirements.
zdot_before_module() {
    local module="$1"
    if [[ -z "$module" ]]; then
        zdot_error "zdot_before_module: module name required"
        return 1
    fi
    shift

    local mode="" fn=""
    local -a cmd_args=()

    while (( $# )); do
        case "$1" in
            --fn)
                [[ -n "$mode" ]] && { zdot_error "zdot_before_module: --fn and --cmd are mutually exclusive"; return 1; }
                [[ -z "$2" ]] && { zdot_error "zdot_before_module: --fn requires a function name"; return 1; }
                mode="fn"
                fn="$2"
                shift 2
                ;;
            --cmd)
                [[ -n "$mode" ]] && { zdot_error "zdot_before_module: --fn and --cmd are mutually exclusive"; return 1; }
                shift
                (( $# )) || { zdot_error "zdot_before_module: --cmd requires a command"; return 1; }
                mode="cmd"
                cmd_args=("$@")
                shift $#
                ;;
            *)
                zdot_error "zdot_before_module: unknown flag '$1' (expected --fn or --cmd)"
                return 1
                ;;
        esac
    done

    if [[ -z "$mode" ]]; then
        zdot_error "zdot_before_module: one of --fn / --cmd must be given"
        return 1
    fi

    if [[ -n "${_ZDOT_MODULES_LOADED[$module]}" ]]; then
        local _what
        if [[ "$mode" == "fn" ]]; then _what="'$fn'"; else _what="--cmd"; fi
        zdot_warn "zdot_before_module: module '$module' is already loaded; $_what will not run"
        return 1
    fi

    # For --cmd, generate a unique callback fn name via the monotonic counter;
    # define the fn body to run the captured command. The function body is the
    # only stored copy of the command — introspection reads it via $functions[].
    if [[ "$mode" == "cmd" ]]; then
        fn="_zdot_before_${module}_${_ZDOT_BEFORE_MODULE_COUNTER}"
        _ZDOT_BEFORE_MODULE_COUNTER=$((_ZDOT_BEFORE_MODULE_COUNTER + 1))
        eval "${fn}() { ${(@qq)cmd_args}; }"
    fi

    # For --fn, dedup. (--cmd always generates a unique name, so no dedup needed.)
    local existing="${_ZDOT_BEFORE_MODULE[$module]:-}"
    if [[ "$mode" == "fn" ]]; then
        case " $existing " in
            *" $fn "*) return 0 ;;
        esac
        # Capture origin for introspection. First writer wins (we only get
        # here when fn is not already registered for this module).
        local _origin
        if [[ -n "$_ZDOT_CURRENT_MODULE_NAME" ]]; then
            _origin="module:$_ZDOT_CURRENT_MODULE_NAME"
        else
            _origin="${funcfiletrace[1]:-unknown}"
        fi
        local _origin_key="${module}::${fn}"
        _ZDOT_BEFORE_MODULE_ORIGIN[$_origin_key]="$_origin"
    fi
    _ZDOT_BEFORE_MODULE[$module]="${existing:+$existing }$fn"
}

# Load a module by name, searching the configured path.
# User-supplied directories (zstyle ':zdot:modules' search-path) are searched
# first; lib/ is always the final fallback. First match wins.
# Usage: zdot_load_module <module-name>
zdot_load_module() {
    local module="$1"
    [[ -z "$module" ]] && { zdot_error "zdot_load_module: module name required"; return 1 }
    _zdot_build_module_search_path
    local dir module_file
    for dir in "${_ZDOT_MODULE_SEARCH_PATH[@]}"; do
        module_file="${dir}/${module}/${module}.zsh"
        if [[ -f "$module_file" ]]; then
            _zdot_load_module_file "$module" "$module_file"
            return $?
        fi
    done
    zdot_error "zdot_load_module: module '${module}' not found in search path"
    return 1
}

# Check whether a module has been loaded.
# Usage: zdot_module_loaded <module-name>
# Returns 0 if loaded, 1 otherwise.
zdot_module_loaded() {
    local module="$1"
    [[ -z "$module" ]] && return 1
    [[ -n "${_ZDOT_MODULES_LOADED[$module]}" ]]
}

# List all loaded modules with their source directory.
# Modules from lib/ are labelled "(lib)"; others show their directory path.
# With --before, also list each module's registered before-module callbacks:
#   --cmd registrations show the captured command
#   --fn  registrations show the function name and its registration origin
# Usage: zdot_module_list [--before]
zdot_module_list() {
    local show_before=0
    while (( $# )); do
        case "$1" in
            --before) show_before=1; shift ;;
            *) zdot_error "zdot_module_list: unknown flag: $1"; return 1 ;;
        esac
    done

    zdot_report "Loaded modules:"
    local module src
    for module in ${(ko)_ZDOT_MODULES_LOADED}; do
        src="${_ZDOT_MODULE_SOURCE_DIR[$module]:-unknown}"
        if [[ "$src" == "${_ZDOT_MODULE_DIR}/${module}" ]]; then
            zdot_info "  ${module}  (modules)"
        else
            zdot_info "  ${module}  (${src})"
        fi

        if (( show_before )) && [[ -n "${_ZDOT_BEFORE_MODULE[$module]:-}" ]]; then
            zdot_info "    before:"
            # Initialise locals on declaration. Re-declaring an existing local
            # WITHOUT an initialiser (e.g. just `local _fn`) makes zsh echo the
            # variable's current value as a typeset-style line.
            local _fn=""
            for _fn in ${=_ZDOT_BEFORE_MODULE[$module]}; do
                # --cmd registrations get framework-namespace names beginning
                # with `_zdot_before_`; anything else came in as --fn <name>.
                if [[ "$_fn" == _zdot_before_* ]]; then
                    # $functions[fn] is the body content only (no `() { … }`
                    # wrapping). For our single-line --cmd definitions the
                    # body has a leading tab inserted by typeset; strip it.
                    local _body="${functions[$_fn]}"
                    _body="${_body#$'\t'}"
                    zdot_info "      cmd: ${_body}"
                else
                    local _key="${module}::${_fn}"
                    local _origin="${_ZDOT_BEFORE_MODULE_ORIGIN[$_key]:-unknown}"
                    zdot_info "      fn: ${_fn}  ← ${_origin}"
                fi
            done
        fi
    done
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
#   --after <target...>           Soft ordering: run load phase after each
#                                 target (phase or hook name), no-op if absent
#   --after-tool <tool>           Soft ordering after whoever provides <tool>
#   --before <target...>          Soft ordering: run load phase before each
#                                 target (phase or hook name), no-op if absent
#   --before-tool <tool>          Soft ordering before whoever provides <tool>
#   --auto-bundle-deps            Match --load-plugins specs to registered bundle
#                                 handlers and auto-wire the load hook's group +
#                                 requires edges
#   --group <name>                Explicit group for the load phase
#   --auto-configure-group        Expose the <basename>-configure extension
#                                 group. The --configure fn (or the load fn,
#                                 if no configure is set) becomes the CONSUMER
#                                 of the group (--requires-group), so it runs
#                                 after all user-registered group hooks have
#                                 had a chance to set state. Users attach with
#                                 --group <basename>-configure. Requires at
#                                 least one of --configure / --load.
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
    local -a after_targets=() before_targets=()
    local -a configure_contexts=() load_contexts=()
    local -a post_init_requires=() post_init_contexts=()
    local auto_bundle=0
    local auto_configure_group=0
    local -a contexts=(interactive noninteractive)
    local -a module_variants=()
    local -a module_variant_excludes=()

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
            --after)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    after_targets+=("$1"); shift
                done
                ;;
            --after-tool)
                after_targets+=("tool:$2"); shift 2 ;;
            --before)
                shift
                while (( $# )) && [[ "$1" != --* ]]; do
                    before_targets+=("$1"); shift
                done
                ;;
            --before-tool)
                before_targets+=("tool:$2"); shift 2 ;;
            --auto-bundle-deps)
                auto_bundle=1; shift ;;
            --auto-configure-group)
                auto_configure_group=1; shift ;;
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
            --variant)
                module_variants+=("$2"); shift 2 ;;
            --variant-exclude)
                module_variant_excludes+=("$2"); shift 2 ;;
            *)
                zdot_warn "zdot_define_module: unknown flag: $1"; shift ;;
        esac
    done

    # Validate: --load and --load-plugins are mutually exclusive
    if [[ -n "$load_fn" ]] && (( ${#load_plugins} )); then
        zdot_error "zdot_define_module: --load and --load-plugins are mutually exclusive"
        return 1
    fi

    # --- Build module-level variant args to forward to every hook ---
    local -a _dm_variant_args=()
    local _dmv
    for _dmv in "${module_variants[@]}"; do
        _dm_variant_args+=(--variant "$_dmv")
    done
    for _dmv in "${module_variant_excludes[@]}"; do
        _dm_variant_args+=(--variant-exclude "$_dmv")
    done

    # --- Configure phase ---
    if [[ -n "$configure_fn" ]]; then
        local -a cfg_ctx=("${contexts[@]}")
        if (( ${#configure_contexts} )); then
            cfg_ctx=("${configure_contexts[@]}")
        fi
        local -a _dm_cfg_extra=()
        # When --auto-configure-group is set, the configure fn is the CONSUMER
        # of the <basename>-configure group: it runs after all user-registered
        # group hooks have contributed state. The configure fn can then read
        # that state (e.g. via zstyle) and apply backstop defaults.
        if (( auto_configure_group )); then
            _dm_cfg_extra+=(--requires-group "${basename}-configure")
        fi
        zdot_register_hook "$configure_fn" "${cfg_ctx[@]}" \
            --name "${basename}-configure" \
            --requires bootstrap-ready \
            --provides "${basename}-configured" \
            "${_dm_cfg_extra[@]}" \
            "${_dm_variant_args[@]}"
    fi

    # --- Load phase ---
    # Whether a load phase exists (used by --auto-configure-group wiring and
    # by the post-init / interactive-init / noninteractive-init blocks below).
    local has_load=0
    if [[ -n "$load_fn" ]] || (( ${#load_plugins} )); then
        has_load=1
    fi

    local load_provides="${basename}-loaded"
    local -a load_hook_args=()

    load_hook_args+=(--name "${basename}-load")
    load_hook_args+=(--provides "$load_provides")

    # If configure exists, load depends on it
    if [[ -n "$configure_fn" ]]; then
        load_hook_args+=(--requires "${basename}-configured")
    fi

    # When --auto-configure-group is set and there is no configure fn, the
    # load fn takes the consumer role instead. (When configure exists, it
    # already has --requires-group, and load waits transitively via the
    # --requires <basename>-configured edge above.)
    if (( auto_configure_group )) && [[ -z "$configure_fn" ]]; then
        if (( has_load )); then
            load_hook_args+=(--requires-group "${basename}-configure")
        else
            zdot_warn "zdot_define_module: --auto-configure-group requested for '${basename}' but no configure or load phase exists; flag ignored"
        fi
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

    # Soft ordering targets (--after / --before) apply to the load phase.
    local _ot
    for _ot in "${after_targets[@]}"; do
        load_hook_args+=(--after "$_ot")
    done
    for _ot in "${before_targets[@]}"; do
        load_hook_args+=(--before "$_ot")
    done

    # Resolve load context: --load-context overrides --context
    local -a ld_ctx=("${contexts[@]}")
    if (( ${#load_contexts} )); then
        ld_ctx=("${load_contexts[@]}")
    fi

    if [[ -n "$load_fn" ]]; then
        # Explicit load function
        zdot_register_hook "$load_fn" "${ld_ctx[@]}" "${load_hook_args[@]}" "${_dm_variant_args[@]}"

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

        zdot_register_hook "$loader_name" "${ld_ctx[@]}" "${load_hook_args[@]}" "${_dm_variant_args[@]}"
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
            --provides "${basename}-post-configured" \
            "${_dm_variant_args[@]}"
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
            --provides "${basename}-interactive-ready" \
            "${_dm_variant_args[@]}"
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
            --provides "${basename}-noninteractive-ready" \
            "${_dm_variant_args[@]}"
    fi
}
