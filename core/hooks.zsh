#!/usr/bin/env zsh
# zdot/hooks: Dependency-based hook management system
# Provides registration, execution, and introspection for dependency-ordered hooks

# ============================================================================
# Global Data Structures
# ============================================================================

# Hook metadata storage
typeset -gA _ZDOT_HOOKS              # hook_id -> function_name
typeset -gA _ZDOT_HOOK_CONTEXTS      # hook_id -> "interactive noninteractive ..."
typeset -gA _ZDOT_HOOK_REQUIRES      # hook_id -> "phase1 phase2 ..."
typeset -gA _ZDOT_HOOK_PROVIDES      # hook_id -> "phase_name"
typeset -gA _ZDOT_HOOK_OPTIONAL      # hook_id -> 1 if optional
typeset -gA _ZDOT_HOOK_ON_DEMAND     # hook_id -> 1 if on-demand
typeset -gA _ZDOT_PHASE_PROVIDERS    # phase_name -> hook_id (reverse lookup)
typeset -gA _ZDOT_PHASES_PROMISED    # phase_name -> 1 when promised (for validation)
typeset -gA _ZDOT_PHASES_PROVIDED    # phase_name -> 1 when actually available at runtime
typeset -gA _ZDOT_HOOKS_EXECUTED     # hook_id -> 1 when executed at runtime
typeset -gA _ZDOT_ON_DEMAND_PHASES   # phase_name -> 1 if explicitly on-demand

typeset -g _ZDOT_HOOK_COUNTER=0
typeset -ga _ZDOT_EXECUTION_PLAN     # Ordered array of hook_ids

# ============================================================================
# Hook Registration
# ============================================================================

# Register a hook function with dependency metadata
# Usage: zdot_hook_register <function-name> <context...> [--requires <phase...>] [--provides <phase>] [--optional] [--on-demand]
# Contexts: interactive, noninteractive, login, nonlogin
# Example: zdot_hook_register _my_init interactive --requires xdg-configured --provides my-ready
zdot_hook_register() {
    local func_name=$1
    shift
    
    local -a contexts
    local -a requires
    local provides=""
    local optional=0
    local on_demand=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --requires)
                shift
                # Collect all phases until we hit another flag or end
                while [[ $# -gt 0 && $1 != --* ]]; do
                    requires+=($1)
                    shift
                done
                ;;
            --provides)
                provides=$2
                shift 2
                ;;
            --optional)
                optional=1
                shift
                ;;
            --on-demand)
                on_demand=1
                shift
                ;;
            *)
                # Context argument
                contexts+=($1)
                shift
                ;;
        esac
    done
    
    # Validation
    if [[ -z "$func_name" ]]; then
        zdot_error "zdot_hook_register: function name required"
        return 1
    fi

    if [[ ${#contexts[@]} -eq 0 ]]; then
        zdot_error "zdot_hook_register: at least one context required (interactive, noninteractive, login, nonlogin)"
        return 1
    fi
    
    # Generate unique hook ID
    (( _ZDOT_HOOK_COUNTER++ ))
    local hook_id="hook_${_ZDOT_HOOK_COUNTER}"
    
    # Store hook metadata
    _ZDOT_HOOKS[$hook_id]=$func_name
    _ZDOT_HOOK_CONTEXTS[$hook_id]="${contexts[*]}"
    _ZDOT_HOOK_REQUIRES[$hook_id]="${requires[*]}"
    _ZDOT_HOOK_PROVIDES[$hook_id]=$provides
    _ZDOT_HOOK_OPTIONAL[$hook_id]=$optional
    _ZDOT_HOOK_ON_DEMAND[$hook_id]=$on_demand
    
    # Mark required phases as on-demand if this hook is on-demand
    if [[ $on_demand -eq 1 ]]; then
        for phase in ${requires[@]}; do
            _ZDOT_ON_DEMAND_PHASES[$phase]=1
        done
    fi
    
    # Register phase provider (for reverse lookup)
    if [[ -n $provides ]]; then
        if [[ -n ${_ZDOT_PHASE_PROVIDERS[$provides]} ]]; then
            zdot_error "zdot_hook_register: ERROR: Multiple hooks provide phase '$provides'"
            zdot_error "  Previous: ${_ZDOT_HOOKS[${_ZDOT_PHASE_PROVIDERS[$provides]}]}"
            zdot_error "  Current: $func_name"
            return 1
        fi
        _ZDOT_PHASE_PROVIDERS[$provides]=$hook_id
    fi
    
    # Track which module registered this hook
    if [[ -n "$_ZDOT_CURRENT_MODULE_NAME" ]]; then
        _ZDOT_HOOK_MODULES[$func_name]="$_ZDOT_CURRENT_MODULE_NAME"
    fi
}

# ============================================================================
# Dependency Resolution (Topological Sort)
# ============================================================================

# Build execution plan using topological sort (Kahn's algorithm)
# Usage: zdot_build_execution_plan
# Determines current context and builds dependency-ordered execution plan
zdot_build_execution_plan() {
    # Determine current shell context
    local -a current_contexts
    if [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]]; then
        current_contexts+=(interactive)
    else
        current_contexts+=(noninteractive)
    fi
    
    if [[ $_ZDOT_IS_LOGIN -eq 1 ]]; then
        current_contexts+=(login)
    else
        current_contexts+=(nonlogin)
    fi
    
    # Build dependency graph for hooks in current context
    local -A in_degree        # hook_id -> count of unsatisfied dependencies
    local -A adjacency_list   # phase_name -> "hook_id1 hook_id2 ..." (hooks that depend on this phase)
    local -a zero_in_degree   # Hooks with no dependencies
    local -a execution_order
    local -a skipped_hooks    # Track skipped optional hooks
    
    # Initialize graph
    for hook_id in ${(k)_ZDOT_HOOKS}; do
        local hook_contexts=(${=_ZDOT_HOOK_CONTEXTS[$hook_id]})
        
        # Check if hook should run in current context
        local context_match=0
        for ctx in "${current_contexts[@]}"; do
            if [[ " ${hook_contexts[*]} " =~ " ${ctx} " ]]; then
                context_match=1
                break
            fi
        done
        
        # Skip hooks not in current context
        if [[ $context_match -eq 0 ]]; then
            continue
        fi
        
        local requires=(${=_ZDOT_HOOK_REQUIRES[$hook_id]})
        local degree=0
        
        # Count dependencies
        for phase in $requires; do
            # Check if phase is promised or has a provider hook
            if [[ -z ${_ZDOT_PHASE_PROVIDERS[$phase]} && -z ${_ZDOT_PHASES_PROMISED[$phase]} ]]; then
                # Required phase has no provider
                if [[ ${_ZDOT_HOOK_OPTIONAL[$hook_id]} == 1 ]]; then
                    skipped_hooks+=("${_ZDOT_HOOKS[$hook_id]} (missing: $phase)")
                    degree=-1  # Mark as skipped
                    break
                else
                    zdot_error "zdot_build_execution_plan: ERROR: Hook '${_ZDOT_HOOKS[$hook_id]}' requires phase '$phase' but no hook provides it"
                    return 1
                fi
            fi
            
            # Only increment degree for phases with actual providers
            # Promised phases are treated as "already available" so hooks depending on them
            # can be added to execution plan, but will be placed at the end
            if [[ -z ${_ZDOT_PHASES_PROMISED[$phase]} ]]; then
                (( degree++ ))
                # Build adjacency list: phase -> hooks that depend on it
                adjacency_list[$phase]+=" $hook_id"
            fi
        done
        
        # Skip if marked as skipped
        if [[ $degree -eq -1 ]]; then
            continue
        fi
        
        in_degree[$hook_id]=$degree
        
        # Add to zero_in_degree queue ONLY if:
        # - degree is 0, AND
        # - hook doesn't depend solely on promised phases (those go at the end)
        if [[ $degree -eq 0 ]]; then
            # Check if this hook depends only on promised phases
            local -a requires_phases=(${=_ZDOT_HOOK_REQUIRES[$hook_id]})
            local depends_only_on_promised=1
            
            if [[ ${#requires_phases} -eq 0 ]]; then
                # No requirements at all - add to queue normally
                depends_only_on_promised=0
            else
                for phase in $requires_phases; do
                    if [[ -z ${_ZDOT_PHASES_PROMISED[$phase]} ]]; then
                        # Depends on at least one non-promised phase
                        depends_only_on_promised=0
                        break
                    fi
                done
            fi
            
            # Only add to initial queue if not depending solely on promised phases
            if [[ $depends_only_on_promised -eq 0 ]]; then
                zero_in_degree+=($hook_id)
            fi
        fi
    done
    
    # Kahn's algorithm for topological sort
    # This processes all hooks that have dependencies on provider hooks
    while [[ ${#zero_in_degree} -gt 0 ]]; do
        # Pop from zero_in_degree queue
        local current_hook=${zero_in_degree[1]}
        zero_in_degree=("${zero_in_degree[@]:1}")
        
        # Add to execution order
        execution_order+=($current_hook)
        
        # Get phase this hook provides
        local provided_phase=${_ZDOT_HOOK_PROVIDES[$current_hook]}
        
        if [[ -n $provided_phase ]]; then
            # Find all hooks that depend on this phase
            local dependent_hooks=(${=adjacency_list[$provided_phase]})
            
            for dep_hook in $dependent_hooks; do
                # Decrease in-degree
                (( in_degree[$dep_hook]-- ))
                
                # If in-degree becomes 0, add to queue
                if [[ ${in_degree[$dep_hook]} -eq 0 ]]; then
                    zero_in_degree+=($dep_hook)
                fi
            done
        fi
    done
    
    # Add hooks that depend ONLY on promised phases to the END of execution order
    # These hooks had degree=0 from the start but were never added because they
    # don't depend on any provider hooks - they only depend on promised phases
    local -a promised_phase_hooks
    for hook_id in ${(k)in_degree}; do
        # Skip hooks already in execution order
        if [[ " ${execution_order[*]} " =~ " ${hook_id} " ]]; then
            continue
        fi
        
        # Check if this hook depends only on promised phases
        local requires=(${=_ZDOT_HOOK_REQUIRES[$hook_id]})
        local depends_only_on_promised=1
        
        for phase in $requires; do
            if [[ -z ${_ZDOT_PHASES_PROMISED[$phase]} ]]; then
                depends_only_on_promised=0
                break
            fi
        done
        
        if [[ $depends_only_on_promised -eq 1 ]]; then
            promised_phase_hooks+=($hook_id)
        fi
    done
    
    # Append promised-phase-only hooks to the END
    execution_order+=($promised_phase_hooks)
    
    # Check for cycles (if any hooks still have in_degree > 0 and don't depend only on promised phases)
    local -a cyclic_hooks
    for hook_id in ${(k)in_degree}; do
        if [[ ${in_degree[$hook_id]} -gt 0 ]]; then
            # Check if hook is already in execution_order (including promised phase hooks)
            if [[ ! " ${execution_order[*]} " =~ " ${hook_id} " ]]; then
                cyclic_hooks+=("${_ZDOT_HOOKS[$hook_id]}")
            fi
        fi
    done
    
    if [[ ${#cyclic_hooks} -gt 0 ]]; then
        zdot_error "zdot_build_execution_plan: ERROR: Circular dependency detected"
        zdot_error "Hooks involved in cycle:"
        for hook in $cyclic_hooks; do
            zdot_error "  - $hook"
        done
        return 1
    fi
    
    # Store execution plan
    _ZDOT_EXECUTION_PLAN=($execution_order)
    
    # Report skipped optional hooks if any
    if [[ ${#skipped_hooks} -gt 0 ]]; then
        for skip_msg in $skipped_hooks; do
            zdot_verbose "zdot: Skipping optional hook: $skip_msg"
        done
    fi
    
    return 0
}

# ============================================================================
# Hook Execution
# ============================================================================

# Promise that a phase will be provided manually later
# Usage: zdot_promise_phase <phase-name>
# This allows hooks to depend on phases that will be provided outside the hook system
# Hooks depending ONLY on promised phases will be placed at the END of the execution order
# Example: zdot_promise_phase finalize; zdot_build_execution_plan; zdot_execute_all
zdot_promise_phase() {
    local phase="$1"
    
    if [[ -z $phase ]]; then
        zdot_error "zdot_promise_phase: ERROR: No phase name specified"
        return 1
    fi
    
    _ZDOT_PHASES_PROMISED[$phase]=1
    return 0
}

# Internal helper to execute a single hook
# Usage: _zdot_execute_hook <hook_id> <function_name> [stop_callback]
# Returns:
#   0 - Success
#   1 - Failure (function failed or not found)
#   2 - Success with early termination signal (stop_callback returned 0)
_zdot_execute_hook() {
    local hook_id="$1"
    local function_name="$2"
    local stop_callback="$3"
    
    local func=${_ZDOT_HOOKS[$hook_id]}
    local provides=${_ZDOT_HOOK_PROVIDES[$hook_id]}
    
    # Execute the hook function
    if typeset -f "$func" > /dev/null; then
        if $func; then
            _ZDOT_HOOKS_EXECUTED[$hook_id]=1
            
            # Mark phase as provided
            if [[ -n $provides ]]; then
                _ZDOT_PHASES_PROVIDED[$provides]=1
                
                # Call stop callback if provided
                if [[ -n $stop_callback ]] && $stop_callback "$provides"; then
                    return 2
                fi
            fi
            return 0
        else
            zdot_error "${function_name}: Hook '$func' failed (exit code: $?)"
            return 1
        fi
    else
        zdot_error "${function_name}: Hook function '$func' not found"
        return 1
    fi
}

# Execute all hooks in dependency order
# Meant for full initialization
zdot_execute_all() {
    if [[ ${#_ZDOT_EXECUTION_PLAN} -eq 0 ]]; then
        zdot_error "zdot_execute_all: ERROR: No execution plan. Call zdot_build_execution_plan first."
        return 1
    fi
    
    local executed=0
    local failed=0
    
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        # Skip if this hook was already executed
        if [[ -n ${_ZDOT_HOOKS_EXECUTED[$hook_id]} ]]; then
            continue
        fi
        
        _zdot_execute_hook "$hook_id" "zdot_execute_all"
        local result=$?
        
        if [[ $result -eq 0 || $result -eq 2 ]]; then
            (( executed++ ))
        else
            (( failed++ ))
        fi
    done
    
    if [[ $failed -gt 0 ]]; then
        zdot_error "zdot_execute_all: Completed with $failed failed hook(s)"
        return 1
    fi
    
    return 0
}

# Execute hooks until a specific phase is provided
# Usage: zdot_run_until <phase>
# Runs hooks in dependency order, stopping after the specified phase is provided
zdot_run_until() {
    local target_phase="$1"
    
    if [[ -z $target_phase ]]; then
        zdot_error "zdot_run_until: ERROR: No target phase specified"
        return 1
    fi

    if [[ ${#_ZDOT_EXECUTION_PLAN} -eq 0 ]]; then
        zdot_error "zdot_run_until: ERROR: No execution plan. Call zdot_build_execution_plan first."
        return 1
    fi
    
    # Check if target phase has already been provided
    if [[ -n ${_ZDOT_PHASES_PROVIDED[$target_phase]} ]]; then
        return 0
    fi
    
    local executed=0
    local failed=0
    
    # Callback to check if we've reached the target phase
    _zdot_check_target_phase() {
        [[ $1 == $target_phase ]]
    }
    
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        # Skip if this hook was already executed
        if [[ -n ${_ZDOT_HOOKS_EXECUTED[$hook_id]} ]]; then
            continue
        fi
        
        _zdot_execute_hook "$hook_id" "zdot_run_until" "_zdot_check_target_phase"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            (( executed++ ))
        elif [[ $result -eq 2 ]]; then
            # Early termination - target phase reached
            (( executed++ ))
            return 0
        else
            (( failed++ ))
        fi
    done
    
    # If we got here, the target phase was never provided
    if [[ $failed -gt 0 ]]; then
        zdot_error "zdot_run_until: Completed with $failed failed hook(s), target phase '$target_phase' not provided"
        return 1
    fi

    zdot_warn "zdot_run_until: WARNING: Target phase '$target_phase' was not provided by any hook"
    return 1
}

# ============================================================================
# Introspection and Debugging
# ============================================================================

# List hooks organized by module
# Usage: zdot_module_hooks [module-name]
zdot_module_hooks() {
    local target_module="$1"

    # Build a map of module -> hooks
    local -A module_hooks

    for hook_id in ${(k)_ZDOT_HOOKS}; do
        local func=${_ZDOT_HOOKS[$hook_id]}
        local module="${_ZDOT_HOOK_MODULES[$func]}"

        # Filter by module if specified
        if [[ -n "$target_module" && "$module" != "$target_module" ]]; then
            continue
        fi

        if [[ -z "${module_hooks[$module]}" ]]; then
            module_hooks[$module]="$func"
        else
            module_hooks[$module]="${module_hooks[$module]} $func"
        fi
    done

    if [[ -n "$target_module" ]]; then
        zdot_info "Hooks registered by module: $target_module"
    else
        zdot_info "Hooks registered by each module:"
    fi
    zdot_info ""

    # Sort modules alphabetically
    for module in ${(ko)module_hooks}; do
        zdot_info "Module: $module"

        local hooks="${module_hooks[$module]}"
        for func in ${=hooks}; do
            # Find hook_id for this function
            local hook_id=""
            for hid in ${(k)_ZDOT_HOOKS}; do
                if [[ ${_ZDOT_HOOKS[$hid]} == $func ]]; then
                    hook_id=$hid
                    break
                fi
            done

            if [[ -n $hook_id ]]; then
                local provides=${_ZDOT_HOOK_PROVIDES[$hook_id]:-"(none)"}
                local requires=${_ZDOT_HOOK_REQUIRES[$hook_id]:-"(none)"}
                zdot_info "  • $func"
                zdot_info "    provides: $provides"
                zdot_info "    requires: $requires"
            fi
        done
        zdot_info ""
    done

    if [[ -z "$target_module" ]]; then
        local total_modules=${#module_hooks[@]}
        zdot_info "Total: $total_modules module(s) with registered hooks"
    fi
}