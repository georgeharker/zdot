#!/usr/bin/env zsh
# zdot/cache: Two-tier caching system for improved startup performance
# Provides bytecode compilation and execution plan caching

# ============================================================================
# Global Data Structures
# ============================================================================

typeset -g _ZDOT_CACHE_ENABLED=0            # Whether caching is enabled
typeset -g _ZDOT_CACHE_DIR=""               # Cache directory path
typeset -g _ZDOT_CACHE_VERSION="3"          # Cache format version (context-aware providers only)

# ============================================================================
# Cache Configuration
# ============================================================================

# Initialize cache system with zstyle configuration
# Usage: zdot_cache_init
zdot_cache_init() {
    # Check if caching is enabled via zstyle
    local enabled
    zstyle -b ':zdot:cache' enabled enabled
    if [[ "$enabled" == "yes" ]]; then
        _ZDOT_CACHE_ENABLED=1
    else
        _ZDOT_CACHE_ENABLED=0
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
        return 0
    fi

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
    local core_dir="${_ZDOT_BASE_DIR}/core"
    if [[ -d "$core_dir" ]]; then
        for core_file in "$core_dir"/*.zsh(N); do
            if [[ -f "$core_file" ]]; then
                if ! zdot_cache_compile_file "$core_file"; then
                    failed=1
                fi
            fi
        done
    fi

    # Compile library modules
    local lib_dir="${_ZDOT_LIB_DIR}"
    if [[ -d "$lib_dir" ]]; then
        for module_dir in "$lib_dir"/*(N/); do
            local module_name="${module_dir:t}"
            local module_file="${module_dir}/${module_name}.zsh"
            if [[ -f "$module_file" ]]; then
                if ! zdot_cache_compile_file "$module_file"; then
                    failed=1
                fi
            fi
        done
    fi

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
            zdot_cache_compile_file "$module_file"
        fi
    fi

    _ZDOT_CURRENT_MODULE_DIR="${module_file:h}"
    _ZDOT_CURRENT_MODULE_NAME="$module"

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
# Returns: String like "interactive_nonlogin" or "noninteractive_nonlogin"
_zdot_cache_context_suffix() {
    local interactive_str="noninteractive"
    local login_str="nonlogin"

    if [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]]; then
        interactive_str="interactive"
    fi

    if [[ $_ZDOT_IS_LOGIN -eq 1 ]]; then
        login_str="login"
    fi

    REPLY="${interactive_str}_${login_str}"
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
        echo "# Hook metadata"

        # Serialize hook metadata
        for hook_id in "${_ZDOT_EXECUTION_PLAN[@]}"; do
            local func_name="${_ZDOT_HOOKS[$hook_id]}"
            local contexts="${_ZDOT_HOOK_CONTEXTS[$hook_id]}"
            local requires="${_ZDOT_HOOK_REQUIRES[$hook_id]}"
            local provides="${_ZDOT_HOOK_PROVIDES[$hook_id]}"
            local optional="${_ZDOT_HOOK_OPTIONAL[$hook_id]}"
            local on_demand="${_ZDOT_HOOK_ON_DEMAND[$hook_id]}"

            echo "_ZDOT_HOOKS[$hook_id]='$func_name'"
            echo "_ZDOT_HOOK_CONTEXTS[$hook_id]='$contexts'"
            echo "_ZDOT_HOOK_REQUIRES[$hook_id]='$requires'"
            echo "_ZDOT_HOOK_PROVIDES[$hook_id]='$provides'"
            echo "_ZDOT_HOOK_OPTIONAL[$hook_id]=$optional"
            echo "_ZDOT_HOOK_ON_DEMAND[$hook_id]=$on_demand"

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
                    local ctx_key="${ctx}:${provides}"
                    echo "_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]='$hook_id'"
                done
                echo "_ZDOT_PHASES_PROMISED[$provides]=1"
            fi

            for phase in ${=requires}; do
                if [[ $on_demand -eq 1 ]]; then
                    echo "_ZDOT_ON_DEMAND_PHASES[$phase]=1"
                fi
            done
        done
    } > "$plan_file"

    # Compile the plan file for faster loading (co-located)
    if ! zcompile "$plan_file" 2>/dev/null; then
        zdot_error "zdot_cache_save_plan: failed to compile plan file"
        return 1
    fi

    return 0
}

# Load the cached execution plan
# Usage: load_cache
# Returns: 0 on success, 1 on error
load_cache() {
    if [[ $_ZDOT_CACHE_ENABLED -eq 0 ]]; then
        return 1
    fi

    # Generate context-specific filename
    _zdot_cache_context_suffix
    local context_suffix="$REPLY"
    local plan_file="${_ZDOT_CACHE_DIR}/plans/execution_plan_${context_suffix}.zsh"
    local compiled_plan="${plan_file}.zwc"

    # Check if plan file exists
    if [[ ! -f "$plan_file" ]]; then
        return 1
    fi

    # Validate cache version
    local cached_version
    cached_version=$(head -n 1 "$plan_file" | grep -oE 'v[0-9]+' | sed 's/v//')
    if [[ "$cached_version" != "$_ZDOT_CACHE_VERSION" ]]; then
        zdot_error "load_cache: cache version mismatch (cached: $cached_version, current: $_ZDOT_CACHE_VERSION)"
        return 1
    fi

    # Check if any source files are newer than the plan
    # This ensures cache invalidation when modules change
    local core_dir="${_ZDOT_BASE_DIR}/core"
    local lib_dir="${_ZDOT_LIB_DIR}"

    for core_file in "$core_dir"/*.zsh(N); do
        if [[ -f "$core_file" ]] && zdot_is_newer_or_missing "$core_file" "$plan_file"; then
            return 1
        fi
    done

    for module_dir in "$lib_dir"/*(N/); do
        local module_name="${module_dir:t}"
        local module_file="${module_dir}/${module_name}.zsh"
        if [[ -f "$module_file" ]] && zdot_is_newer_or_missing "$module_file" "$plan_file"; then
            return 1
        fi
    done

    local zdot_entry="${_ZDOT_BASE_DIR}/zdot.zsh"
    if [[ -f "$zdot_entry" ]] && zdot_is_newer_or_missing "$zdot_entry" "$plan_file"; then
        return 1
    fi

    local zshrc_file="${ZDOTDIR:-$HOME}/.zshrc"
    if [[ -f "$zshrc_file" ]] && zdot_is_newer_or_missing "${zshrc_file:A}" "$plan_file"; then
        return 1
    fi

    # Whilst cache.zsh is loaded before plugins.zsh, when load_cache
    # runs, zdot_plugins_have_changed should be available,
    # this check is just defensive.
    if (( ${+functions[zdot_plugins_have_changed]} )) && zdot_plugins_have_changed; then
        typeset -g _ZDOT_FORCE_COMPDUMP_REFRESH=1
        return 1
    fi

    # Load the cached plan (zsh will automatically use .zwc if available)
    source "$plan_file"

    # Validate that the sourced plan actually populated the execution plan.
    # An empty plan can be written when hooks aren't registered yet at save
    # time; treat it as a cache miss so the plan gets rebuilt.
    if [[ ${#_ZDOT_EXECUTION_PLAN} -eq 0 ]]; then
        zdot_error "load_cache: cached plan is empty, forcing rebuild"
        return 1
    fi

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

    # Remove co-located .zwc files from core and lib directories
    local core_dir="${_ZDOT_BASE_DIR}/core"
    local lib_dir="${_ZDOT_LIB_DIR}"

    # Remove compiled core files
    if [[ -d "$core_dir" ]]; then
        for zwc_file in "$core_dir"/*.zwc(N); do
            if [[ -f "$zwc_file" ]]; then
                rm -f "$zwc_file"
            fi
        done
    fi

    # Remove compiled library modules
    if [[ -d "$lib_dir" ]]; then
        for module_dir in "$lib_dir"/*(N/); do
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
    
    # Count co-located .zwc files in core/ and lib/
    local core_count=0
    local lib_count=0
    
    if [[ -d "${_ZDOT_BASE_DIR}/core" ]]; then
        core_count=$(find "${_ZDOT_BASE_DIR}/core" -name "*.zwc" 2>/dev/null | wc -l | tr -d ' ')
    fi
    
    if [[ -d "${_ZDOT_LIB_DIR}" ]]; then
        lib_count=$(find "${_ZDOT_LIB_DIR}" -name "*.zwc" 2>/dev/null | wc -l | tr -d ' ')
    fi
    
    local compiled_count=$((core_count + lib_count))
    
    # Check for context-specific execution plan
    local plan_file="${_ZDOT_CACHE_DIR}/plans/execution_plan_${context_suffix}.zsh"
    local plan_exists=0
    
    if [[ -f "$plan_file" ]]; then
        plan_exists=1
    fi

    echo "Context: $context_suffix"
    echo "Compiled modules (co-located): $compiled_count"
    echo "  - Core modules: $core_count"
    echo "  - Lib modules: $lib_count"
    echo "Execution plan cached: $plan_exists"

    if [[ $plan_exists -eq 1 ]]; then
        echo "Plan created: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$plan_file" 2>/dev/null || stat -c "%y" "$plan_file" 2>/dev/null | cut -d. -f1)"
    fi
}
