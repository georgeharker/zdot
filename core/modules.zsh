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
# Handles dedup, existence check, source/cache, marks _ZDOT_MODULES_LOADED
# and _ZDOT_MODULE_SOURCE_DIR.
# Usage: _zdot_load_module_file <module-name> <module-file>
_zdot_load_module_file() {
    local module="$1" module_file="$2"
    [[ -n "${_ZDOT_MODULES_LOADED[$module]}" ]] && return 0
    if [[ ! -f "$module_file" ]]; then
        zdot_error "_zdot_load_module_file: module file not found: $module_file"
        return 1
    fi
    _zdot_source_module "$module" "$module_file"
    _ZDOT_MODULES_LOADED[$module]=1
    _ZDOT_MODULE_SOURCE_DIR[$module]="${module_file:h}"
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

# List all loaded modules with their source directory.
# Modules from lib/ are labelled "(lib)"; others show their directory path.
# Usage: zdot_module_list
zdot_module_list() {
    zdot_report "Loaded modules:"
    local module src
    for module in ${(ko)_ZDOT_MODULES_LOADED}; do
        src="${_ZDOT_MODULE_SOURCE_DIR[$module]:-unknown}"
        if [[ "$src" == "${_ZDOT_MODULE_DIR}/${module}" ]]; then
            zdot_info "  ${module}  (modules)"
        else
            zdot_info "  ${module}  (${src})"
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
        zdot_register_hook "$configure_fn" "${cfg_ctx[@]}" \
            --name "${basename}-configure" \
            --requires xdg-configured \
            --provides "${basename}-configured" \
            "${_dm_variant_args[@]}"
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
