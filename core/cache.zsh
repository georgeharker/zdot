#!/usr/bin/env zsh
# zdot/cache: Two-tier caching system for improved startup performance
# Provides bytecode compilation and execution plan caching

# ============================================================================
# Global Data Structures
# ============================================================================

typeset -g _ZDOT_CACHE_ENABLED=0            # Whether caching is enabled
typeset -g _ZDOT_CACHE_DIR=""               # Cache directory path
 typeset -g _ZDOT_CACHE_VERSION="20"         # Cache format version (bump to invalidate stale plans)

# ============================================================================
# Cache Configuration
# ============================================================================

# Initialize cache system with zstyle configuration
# Usage: zdot_cache_init
zdot_cache_init() {
    # Check if caching is enabled via zstyle (opt-out: enabled by default)
    if zstyle -T ':zdot:cache' enabled; then
        _ZDOT_CACHE_ENABLED=1
    else
        _ZDOT_CACHE_ENABLED=0
        zdot_verbose "zdot: cache: disabled"
        return 0
    fi

    # Get cache directory from zstyle or use default
    local cache_dir
    zstyle -s ':zdot:cache' directory cache_dir
    if [[ -z "$cache_dir" ]]; then
        cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zdot"
    fi

    # Expand tilde and environment variables
    cache_dir="${~cache_dir}"
    _ZDOT_CACHE_DIR="$cache_dir"

    # Create cache directory structure
    if ! zdot_cache_create_dirs; then
        zdot_error "zdot_cache_init: failed to create cache directories, disabling cache"
        _ZDOT_CACHE_ENABLED=0
        return 1
    fi

    zdot_verbose "zdot: cache: enabled, dir: $_ZDOT_CACHE_DIR"
    return 0
}

# Check if caching is enabled
# Usage: zdot_cache_is_enabled
# Returns: 0 if enabled, 1 if disabled
zdot_cache_is_enabled() {
    [[ $_ZDOT_CACHE_ENABLED -eq 1 ]]
}

# Create cache directory structure
# Usage: zdot_cache_create_dirs
zdot_cache_create_dirs() {
    local cache_dir="$_ZDOT_CACHE_DIR"

    if [[ -z "$cache_dir" ]]; then
        zdot_error "zdot_cache_create_dirs: cache directory not set"
        return 1
    fi

    # Create main cache directory
    if [[ ! -d "$cache_dir" ]]; then
        if ! mkdir -p "$cache_dir" 2>/dev/null; then
            zdot_error "zdot_cache_create_dirs: failed to create cache directory: $cache_dir"
            return 1
        fi
    fi

    # Create subdirectory for execution plans
    # Note: Module bytecode (.zwc) files are co-located with source files, not stored here
    local plans_dir="${cache_dir}/plans"

    if [[ ! -d "$plans_dir" ]]; then
        if ! mkdir -p "$plans_dir" 2>/dev/null; then
            zdot_error "zdot_cache_create_dirs: failed to create plans directory: $plans_dir"
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# Tier 1: Bytecode Compilation
# ============================================================================

# Compile a zsh file to bytecode (.zwc)
# Usage: zdot_cache_compile_file <source-file>
# Returns: 0 on success, 1 on error
# Note: Creates .zwc file alongside the source file (co-located)
zdot_cache_compile_file() {
    local source_file="$1"

    if [[ -z "$source_file" ]]; then
        zdot_error "zdot_cache_compile_file: source file required"
        return 1
    fi

    if [[ ! -f "$source_file" ]]; then
        zdot_error "zdot_cache_compile_file: source file not found: $source_file"
        return 1
    fi

    # Get compiled path (co-located .zwc file)
    local output_file="${source_file}.zwc"

    # Check if compilation is needed (source newer than compiled)
    if [[ -f "$output_file" ]] && ! zdot_is_newer_or_missing "$source_file" "$output_file"; then
        zdot_verbose "zdot: cache: compile skip (up to date): ${source_file:t}"
        return 0
    fi

    zdot_verbose "zdot: cache: compiling: ${source_file:t}"
    # Compile source file (creates .zwc next to it)
    if ! zcompile "$output_file" "$source_file" 2>/dev/null; then
        zdot_error "zdot_cache_compile_file: compilation failed for: $source_file"
        return 1
    fi

    return 0
}

# Compile all core modules and library modules
# Usage: zdot_cache_compile_all
# Returns: 0 on success, 1 if any compilation failed
zdot_cache_compile_all() {
    if [[ $_ZDOT_CACHE_ENABLED -eq 0 ]]; then
        return 0
    fi

    local failed=0

    # Compile core modules
    local core_dir="${ZDOT_DIR}/core"
    if [[ -d "$core_dir" ]]; then
        for core_file in "$core_dir"/*.zsh(N); do
            if [[ -f "$core_file" ]]; then
                if ! zdot_cache_compile_file "$core_file"; then
                    failed=1
                fi
            fi
        done
    fi

    # Compile every module that was actually loaded, using the recorded source dir.
    # This is path-model-correct: it only compiles files we know about, regardless
    # of which directory they came from.
    local module src_dir module_file
    for module in "${(k)_ZDOT_MODULE_SOURCE_DIR}"; do
        src_dir="${_ZDOT_MODULE_SOURCE_DIR[$module]}"
        module_file="${src_dir}/${module}.zsh"
        if [[ -f "$module_file" ]]; then
            if ! zdot_cache_compile_file "$module_file"; then
                failed=1
            fi
        fi
    done

    if [[ $failed -eq 1 ]]; then
        zdot_error "zdot_cache_compile_all: some compilations failed"
        return 1
    fi

    return 0
}

# Compile-if-needed and source a module file.
# Sets/clears context vars (_ZDOT_CURRENT_MODULE_DIR, _ZDOT_CURRENT_MODULE_NAME).
# Does NOT touch _ZDOT_MODULES_LOADED — caller is responsible for that.
# Usage: _zdot_source_module <module-name> <module-file>
# Returns: 0 on success, 1 on error
_zdot_source_module() {
    local module="$1"
    local module_file="$2"

    if zdot_cache_is_enabled; then
        local compiled_path="${module_file}.zwc"
        if zdot_is_newer_or_missing "$module_file" "$compiled_path"; then
            zdot_verbose "zdot: cache: recompiling module: $module"
            zdot_cache_compile_file "$module_file"
        fi
    fi

    _ZDOT_CURRENT_MODULE_DIR="${module_file:h}"
    _ZDOT_CURRENT_MODULE_NAME="$module"

    zdot_verbose "zdot: cache: sourcing module: $module"
    # Source the .zsh file — zsh automatically uses .zwc if present
    source "$module_file"

    unset _ZDOT_CURRENT_MODULE_DIR
    unset _ZDOT_CURRENT_MODULE_NAME

    return 0
}

# ============================================================================
# Tier 2: Execution Plan Caching
# ============================================================================

# Generate context-specific suffix for execution plan filenames
# Usage: _zdot_cache_context_suffix
# Returns: String like "interactive_nonlogin_default" or "interactive_login_work"
_zdot_cache_context_suffix() {
    local interactive_str="noninteractive"
    local login_str="nonlogin"
    local variant_str="${_ZDOT_VARIANT:-default}"

    if [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]]; then
        interactive_str="interactive"
    fi

    if [[ $_ZDOT_IS_LOGIN -eq 1 ]]; then
        login_str="login"
    fi

    REPLY="${interactive_str}_${login_str}_${variant_str}"
}

# Serialize the execution plan to cache
# Usage: zdot_cache_save_plan
# Returns: 0 on success, 1 on error
zdot_cache_save_plan() {
    if [[ $_ZDOT_CACHE_ENABLED -eq 0 ]]; then
        return 0
    fi

    # Generate context-specific filename
    _zdot_cache_context_suffix
    local context_suffix="$REPLY"
    local plan_file="${_ZDOT_CACHE_DIR}/plans/execution_plan_${context_suffix}.zsh"

    # Create output directory if needed
    local plan_dir="${plan_file:h}"
    if [[ ! -d "$plan_dir" ]]; then
        if ! mkdir -p "$plan_dir" 2>/dev/null; then
            zdot_error "zdot_cache_save_plan: failed to create plan directory: $plan_dir"
            return 1
        fi
    fi

    zdot_verbose "zdot: cache: saving plan: ${plan_file:t}"
    # Write the execution plan to file
    {
        echo "# zdot execution plan cache v${_ZDOT_CACHE_VERSION}"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "# Execution plan order"
        echo "typeset -ga _ZDOT_EXECUTION_PLAN=("

        for hook_id in "${_ZDOT_EXECUTION_PLAN[@]}"; do
            echo "    \"$hook_id\""
        done

        echo ")"
        echo ""
        echo "# Deferred plan entries (subset of execution plan)"
        echo "typeset -ga _ZDOT_EXECUTION_PLAN_DEFERRED=("

        for hook_id in "${_ZDOT_EXECUTION_PLAN_DEFERRED[@]}"; do
            echo "    \"$hook_id\""
        done

        echo ")"
        echo ""
        echo "# Hook metadata"

        # Serialize hook metadata
        for hook_id in "${_ZDOT_EXECUTION_PLAN[@]}"; do
            local func_name="${_ZDOT_HOOKS[$hook_id]}"
            local name="${_ZDOT_HOOK_NAMES[$hook_id]}"
            local contexts="${_ZDOT_HOOK_CONTEXTS[$hook_id]}"
            local requires="${_ZDOT_HOOK_REQUIRES[$hook_id]}"
            local provides="${_ZDOT_HOOK_PROVIDES[$hook_id]}"
            local optional="${_ZDOT_HOOK_OPTIONAL[$hook_id]}"

            echo "_ZDOT_HOOKS[$hook_id]='$func_name'"
            echo "_ZDOT_HOOK_NAMES[$hook_id]='$name'"
            echo "_ZDOT_HOOK_CONTEXTS[$hook_id]='$contexts'"
            echo "_ZDOT_HOOK_REQUIRES[$hook_id]='$requires'"
            # Serialise context restrictions on individual requires.
            # Absent entry means unconditional (all contexts) — existing behaviour.
            for _phase in ${=requires}; do
                local _req_ctx_key="${hook_id}:${_phase}"
                if [[ -v "_ZDOT_HOOK_REQUIRES_CONTEXTS[$_req_ctx_key]" ]]; then
                    echo "_ZDOT_HOOK_REQUIRES_CONTEXTS[$_req_ctx_key]='${_ZDOT_HOOK_REQUIRES_CONTEXTS[$_req_ctx_key]}'"
                fi
            done
            echo "_ZDOT_HOOK_PROVIDES[$hook_id]='$provides'"
            echo "_ZDOT_HOOK_OPTIONAL[$hook_id]=$optional"

            if [[ -n "$provides" ]]; then
                # Serialize context-aware providers
                # NOTE: We intentionally serialize provider mappings for ALL contexts that
                # this hook declares, not just the current context. This causes some
                # duplication across cache files (e.g., a hook with contexts="interactive
                # noninteractive" gets both mappings written to each cache file), but it's
                # necessary to maintain accuracy in debug commands like zdot_hooks_list
                # which need to show complete provider relationships across all contexts.
                # The duplication is minimal (typically 20-50 lines per cache file) and
                # preserves cache file self-documentation.
                for ctx in ${=contexts}; do
                    for phase in ${=provides}; do
                        local ctx_key="${ctx}:${phase}"
                        echo "_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]='$hook_id'"
                    done
                done
            fi
        done

        echo ""
        echo "# Deferred hooks"
        echo "typeset -ga _ZDOT_DEFERRED_HOOKS=("

        for hook_id in "${_ZDOT_DEFERRED_HOOKS[@]}"; do
            echo "    \"$hook_id\""
        done

        echo ")"
        echo ""
        echo "# Deferred hook metadata"

        for hook_id in "${_ZDOT_DEFERRED_HOOKS[@]}"; do
            local func_name="${_ZDOT_HOOKS[$hook_id]}"
            local name="${_ZDOT_HOOK_NAMES[$hook_id]}"
            local contexts="${_ZDOT_HOOK_CONTEXTS[$hook_id]}"
            local requires="${_ZDOT_HOOK_REQUIRES[$hook_id]}"
            local provides="${_ZDOT_HOOK_PROVIDES[$hook_id]}"
            local optional="${_ZDOT_HOOK_OPTIONAL[$hook_id]}"

            echo "_ZDOT_HOOKS[$hook_id]='$func_name'"
            echo "_ZDOT_HOOK_NAMES[$hook_id]='$name'"
            echo "_ZDOT_HOOK_CONTEXTS[$hook_id]='$contexts'"
            echo "_ZDOT_HOOK_REQUIRES[$hook_id]='$requires'"
            # Serialise context restrictions on individual requires.
            for _phase in ${=requires}; do
                local _req_ctx_key="${hook_id}:${_phase}"
                if [[ -v "_ZDOT_HOOK_REQUIRES_CONTEXTS[$_req_ctx_key]" ]]; then
                    echo "_ZDOT_HOOK_REQUIRES_CONTEXTS[$_req_ctx_key]='${_ZDOT_HOOK_REQUIRES_CONTEXTS[$_req_ctx_key]}'"
                fi
            done
            echo "_ZDOT_HOOK_PROVIDES[$hook_id]='$provides'"
            echo "_ZDOT_HOOK_OPTIONAL[$hook_id]=$optional"
        done

        echo ""
        echo "# Defer flag-set name lookup (flag-set key -> display name)"
        echo "typeset -gA _ZDOT_DEFER_FLAG_NAMES=()"
        for _flag_key in "${(@k)_ZDOT_DEFER_FLAG_NAMES}"; do
            echo "_ZDOT_DEFER_FLAG_NAMES[${(q)_flag_key}]=${(q)_ZDOT_DEFER_FLAG_NAMES[$_flag_key]}"
        done

        echo ""
        echo "# Deferred hook dispatch args"
        echo "typeset -gA _ZDOT_HOOK_DEFER_ARGS=()"
        for hook_id in "${_ZDOT_DEFERRED_HOOKS[@]}"; do
            if [[ -n "${_ZDOT_HOOK_DEFER_ARGS[$hook_id]+set}" ]]; then
                echo "_ZDOT_HOOK_DEFER_ARGS[${hook_id}]=${(q)_ZDOT_HOOK_DEFER_ARGS[$hook_id]}"
            fi
        done

        echo ""
        echo "# Defer order dependencies (stride-3: context_spec from_name to_name)"
        echo "typeset -ga _ZDOT_DEFER_ORDER_DEPENDENCIES=("
        for _dop in "${_ZDOT_DEFER_ORDER_DEPENDENCIES[@]}"; do
            echo "    ${(q)_dop}"
        done
        echo ")"

        echo ""
        echo "# Defer order warnings"
        echo "typeset -ga _ZDOT_DEFER_ORDER_WARNINGS=("
        for _dow in "${_ZDOT_DEFER_ORDER_WARNINGS[@]}"; do
            echo "    ${(q)_dow}"
        done
        echo ")"

        echo ""
        echo "# Forced-deferred warnings (re-emitted every shell start)"
        echo "typeset -ga _ZDOT_FORCED_DEFERRED_WARNINGS=("
        for _fdw in "${_ZDOT_FORCED_DEFERRED_WARNINGS[@]}"; do
            echo "    ${(q)_fdw}"
        done
        echo ")"

        echo ""
        echo "# Hook group membership (multi-group forward map)"
        echo "typeset -gA _ZDOT_HOOK_GROUPS=()"
        local _hg_id
        for _hg_id in "${(k)_ZDOT_HOOK_GROUPS[@]}"; do
            echo "_ZDOT_HOOK_GROUPS[${_hg_id}]=${(q)_ZDOT_HOOK_GROUPS[$_hg_id]}"
        done

        echo ""
        echo "# Group member index (reverse map)"
        echo "typeset -gA _ZDOT_GROUP_MEMBERS=()"
        local _gm_name
        for _gm_name in "${(k)_ZDOT_GROUP_MEMBERS[@]}"; do
            echo "_ZDOT_GROUP_MEMBERS[${(q)_gm_name}]=${(q)_ZDOT_GROUP_MEMBERS[$_gm_name]}"
        done

        echo ""
        echo "# Variant constraints per hook (include lists)"
        echo "typeset -gA _ZDOT_HOOK_VARIANTS=()"
        local _hv_id
        for _hv_id in "${(k)_ZDOT_HOOK_VARIANTS[@]}"; do
            [[ -n "${_ZDOT_HOOK_VARIANTS[$_hv_id]}" ]] || continue
            echo "_ZDOT_HOOK_VARIANTS[${_hv_id}]=${(q)_ZDOT_HOOK_VARIANTS[$_hv_id]}"
        done

        echo ""
        echo "# Variant exclude constraints per hook (exclude lists)"
        echo "typeset -gA _ZDOT_HOOK_VARIANT_EXCLUDES=()"
        local _hve_id
        for _hve_id in "${(k)_ZDOT_HOOK_VARIANT_EXCLUDES[@]}"; do
            [[ -n "${_ZDOT_HOOK_VARIANT_EXCLUDES[$_hve_id]}" ]] || continue
            echo "_ZDOT_HOOK_VARIANT_EXCLUDES[${_hve_id}]=${(q)_ZDOT_HOOK_VARIANT_EXCLUDES[$_hve_id]}"
        done

        echo ""
        echo "# Active variant (resolved at plan-build time)"
        echo "typeset -g _ZDOT_VARIANT=${(q)_ZDOT_VARIANT:-}"
        echo "typeset -g _ZDOT_VARIANT_DETECTED=1"
    } > "$plan_file"

    # Compile the plan file for faster loading (co-located)
    if ! zcompile "$plan_file" 2>/dev/null; then
        zdot_error "zdot_cache_save_plan: failed to compile plan file"
        return 1
    fi

    zdot_verbose "zdot: cache: plan compiled ok"
    return 0
}

# Load the cached execution plan
# Usage: load_cache
# Returns: 0 on success, 1 on error
load_cache() {
    if [[ $_ZDOT_CACHE_ENABLED -eq 0 ]]; then
        zdot_verbose "zdot: cache: disabled, skipping plan load"
        return 1
    fi

    # Generate context-specific filename
    _zdot_cache_context_suffix
    local context_suffix="$REPLY"
    local plan_file="${_ZDOT_CACHE_DIR}/plans/execution_plan_${context_suffix}.zsh"
    local compiled_plan="${plan_file}.zwc"

    # Check if plan file exists
    if [[ ! -f "$plan_file" ]]; then
        zdot_verbose "zdot: cache: no plan file: $plan_file"
        return 1
    fi

    # Validate cache version
    local cached_version
    cached_version=$(head -n 1 "$plan_file" | grep -oE 'v[0-9]+' | sed 's/v//')
    if [[ "$cached_version" != "$_ZDOT_CACHE_VERSION" ]]; then
        zdot_verbose "zdot: cache: version mismatch (cached: $cached_version, current: $_ZDOT_CACHE_VERSION)"
        _zdot_internal_warn "load_cache: cache version mismatch (cached: $cached_version, current: $_ZDOT_CACHE_VERSION) — rebuilding"
        return 1
    fi

    # Check if any source files are newer than the plan
    # This ensures cache invalidation when modules change
    local core_dir="${ZDOT_DIR}/core"
    local module_dir="${_ZDOT_MODULE_DIR}"

    for core_file in "$core_dir"/*.zsh(N); do
        if [[ -f "$core_file" ]] && zdot_is_newer_or_missing "$core_file" "$plan_file"; then
            zdot_verbose "zdot: cache: invalidated — core file newer: ${core_file:t}"
            return 1
        fi
    done

    for module_dir in ""/*(N/); do
        local module_name="${module_dir:t}"
        local module_file="${module_dir}/${module_name}.zsh"
        if [[ -f "$module_file" ]] && zdot_is_newer_or_missing "$module_file" "$plan_file"; then
            zdot_verbose "zdot: cache: invalidated — module newer: $module_name"
            return 1
        fi
    done

    # Also check user module directories in the search path
    _zdot_build_module_search_path
    local _sp_dir
    for _sp_dir in "${_ZDOT_MODULE_SEARCH_PATH[@]}"; do
        [[ "$_sp_dir" == "" ]] && continue   # already checked above
        for module_dir in "$_sp_dir"/*(N/); do
            local module_name="${module_dir:t}"
            local module_file="${module_dir}/${module_name}.zsh"
            if [[ -f "$module_file" ]] && zdot_is_newer_or_missing "$module_file" "$plan_file"; then
                zdot_verbose "zdot: cache: invalidated — user module newer: $module_name"
                return 1
            fi
        done
    done

    local zdot_entry="${ZDOT_DIR}/zdot.zsh"
    if [[ -f "$zdot_entry" ]] && zdot_is_newer_or_missing "$zdot_entry" "$plan_file"; then
        zdot_verbose "zdot: cache: invalidated — zdot.zsh modified"
        return 1
    fi

    local zshrc_file="${ZDOTDIR:-$HOME}/.zshrc"
    if [[ -f "$zshrc_file" ]] && zdot_is_newer_or_missing "$zshrc_file" "$plan_file"; then
        zdot_verbose "zdot: cache: invalidated — .zshrc modified"
        return 1
    fi

    # Whilst cache.zsh is loaded before plugins.zsh, when load_cache
    # runs, zdot_plugins_have_changed should be available,
    # this check is just defensive.
    if (( ${+functions[zdot_plugins_have_changed]} )) && zdot_plugins_have_changed; then
        zdot_verbose "zdot: cache: invalidated — plugins changed"
        typeset -g _ZDOT_FORCE_COMPDUMP_REFRESH=1
        return 1
    fi

    # Load the cached plan (zsh will automatically use .zwc if available)
    source "$plan_file"

    # Re-emit defer order warnings (unsatisfiable orderings must be shown every invocation)
    for _w in "${_ZDOT_DEFER_ORDER_WARNINGS[@]}"; do
        _zdot_internal_warn "$_w"
    done

    # Re-emit forced-deferred warnings (hooks auto-deferred due to deferred dependency)
    for _w in "${_ZDOT_FORCED_DEFERRED_WARNINGS[@]}"; do
        _zdot_internal_warn "$_w"
    done

    # Validate that the sourced plan actually populated the execution plan.
    # An empty plan can be written when hooks aren't registered yet at save
    # time; treat it as a cache miss so the plan gets rebuilt.
    if [[ ${#_ZDOT_EXECUTION_PLAN} -eq 0 ]]; then
        zdot_verbose "zdot: cache: plan empty, forcing rebuild"
        _zdot_internal_warn "load_cache: cached plan is empty, forcing rebuild"
        return 1
    fi

    zdot_verbose "zdot: cache: plan loaded (${#_ZDOT_EXECUTION_PLAN} hooks): ${plan_file:t}"
    return 0
}

# Invalidate all caches
# Usage: zdot_cache_invalidate
zdot_cache_invalidate() {
    if [[ $_ZDOT_CACHE_ENABLED -eq 0 ]]; then
        return 0
    fi

    local cache_dir="$_ZDOT_CACHE_DIR"

    if [[ -z "$cache_dir" ]]; then
        zdot_error "zdot_cache_invalidate: cache directory not set"
        return 1
    fi

    # Remove execution plan cache
    if [[ -d "$cache_dir/plans" ]]; then
        rm -rf "${cache_dir}/plans"
        zdot_cache_create_dirs
    fi

    # Remove co-located .zwc files from core directory
    local core_dir="${ZDOT_DIR}/core"

    # Remove compiled core files
    if [[ -d "$core_dir" ]]; then
        for zwc_file in "$core_dir"/*.zwc(N); do
            if [[ -f "$zwc_file" ]]; then
                rm -f "$zwc_file"
            fi
        done
    fi

    # Remove compiled module files using the source-dir map.
    # This is path-model-correct: removes .zwc for every loaded module
    # regardless of which directory (lib/ or user) it came from.
    local module src_dir
    for module in "${(k)_ZDOT_MODULE_SOURCE_DIR}"; do
        src_dir="${_ZDOT_MODULE_SOURCE_DIR[$module]}"
        for zwc_file in "${src_dir}"/*.zwc(N); do
            if [[ -f "$zwc_file" ]]; then
                rm -f "$zwc_file"
            fi
        done
    done

    # Fallback: if no modules are loaded (e.g. called before zdot_init),
    # fall back to scanning lib/ directly so a bare `zdot cache invalidate`
    # still clears lib/ bytecode.
    if [[ ${#_ZDOT_MODULE_SOURCE_DIR} -eq 0 && -d "${_ZDOT_MODULE_DIR}" ]]; then
        for module_dir in "${_ZDOT_MODULE_DIR}"/*(N/); do
            for zwc_file in "$module_dir"/*.zwc(N); do
                if [[ -f "$zwc_file" ]]; then
                    rm -f "$zwc_file"
                fi
            done
        done
    fi

    if (( ${+_ZDOT_COMPDUMP_META_FILE} )) && [[ -f "$_ZDOT_COMPDUMP_META_FILE" ]]; then
        rm -f "$_ZDOT_COMPDUMP_META_FILE"
    fi
    if (( ${+_ZDOT_PLUGINS_REV_STAMP} )) && [[ -f "$_ZDOT_PLUGINS_REV_STAMP" ]]; then
        rm -f "$_ZDOT_PLUGINS_REV_STAMP"
    fi

    return 0
}

# Show cache statistics
# Usage: zdot_cache_stats
zdot_cache_stats() {
    echo "=== zdot Cache Statistics ==="
    echo ""
    echo "Cache enabled: $_ZDOT_CACHE_ENABLED"
    echo "Cache directory: $_ZDOT_CACHE_DIR"
    echo "Cache version: $_ZDOT_CACHE_VERSION"
    echo ""

    if [[ $_ZDOT_CACHE_ENABLED -eq 0 ]]; then
        echo "Caching is disabled"
        return 0
    fi

    # Get current shell context
    _zdot_cache_context_suffix
    local context_suffix="$REPLY"

    # Count co-located .zwc files.
    # Core: scan core/ directory directly.
    # Modules: use the source-dir map so we count exactly what was loaded,
    # from wherever it came from (lib/ or user search-path dirs).
    local core_count=0
    local lib_count=0
    local user_count=0

    if [[ -d "${ZDOT_DIR}/core" ]]; then
        core_count=$(find "${ZDOT_DIR}/core" -maxdepth 1 -name "*.zwc" 2>/dev/null | wc -l | tr -d ' ')
    fi

    local module src_dir
    for module in "${(k)_ZDOT_MODULE_SOURCE_DIR}"; do
        src_dir="${_ZDOT_MODULE_SOURCE_DIR[$module]}"
        local zwc_file="${src_dir}/${module}.zsh.zwc"
        if [[ -f "$zwc_file" ]]; then
            if [[ "$src_dir" == "${_ZDOT_MODULE_DIR}/${module}" ]]; then
                (( lib_count++ ))
            else
                (( user_count++ ))
            fi
        fi
    done

    local compiled_count=$(( core_count + lib_count + user_count ))
    
    # Check for context-specific execution plan
    local plan_file="${_ZDOT_CACHE_DIR}/plans/execution_plan_${context_suffix}.zsh"
    local plan_exists=0
    
    if [[ -f "$plan_file" ]]; then
        plan_exists=1
    fi

    echo "Context: $context_suffix"
    echo "Compiled modules (co-located): $compiled_count"
    echo "  - Core modules: $core_count"
    echo "  - Built-in modules: $lib_count"
    echo "  - User modules: $user_count"
    echo "Execution plan cached: $plan_exists"

    if [[ $plan_exists -eq 1 ]]; then
        echo "Plan created: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$plan_file" 2>/dev/null || stat -c "%y" "$plan_file" 2>/dev/null | cut -d. -f1)"
    fi
}
