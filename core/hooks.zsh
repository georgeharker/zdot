#!/usr/bin/env zsh
# zsh-base/hooks: Phase and hook management system
# Provides registration, execution, and introspection for phase-based hooks

# ============================================================================
# Phase Management
# ============================================================================

# Register a hook function to run during a named phase
# Usage: zdot_hook_register <phase-name> <function-name>
zdot_hook_register() {
    local phase="$1"
    local func="$2"

    if [[ -z "$phase" || -z "$func" ]]; then
        echo "zdot_hook_register: phase and function required" >&2
        return 1
    fi

    # Initialize phase array if it doesn't exist
    if [[ -z "${_ZDOT_PHASES[$phase]}" ]]; then
        _ZDOT_PHASES[$phase]=""
    fi

    # Append function to phase
    if [[ -z "${_ZDOT_PHASES[$phase]}" ]]; then
        _ZDOT_PHASES[$phase]="$func"
    else
        _ZDOT_PHASES[$phase]="${_ZDOT_PHASES[$phase]} $func"
    fi

    # Track which module registered this hook
    if [[ -n "$_ZDOT_CURRENT_MODULE_NAME" ]]; then
        _ZDOT_HOOK_MODULES[$func]="$_ZDOT_CURRENT_MODULE_NAME"
    fi
}

# Execute all hooks registered for a phase
# Usage: zdot_phase_run <phase-name>
zdot_phase_run() {
    local phase="$1"

    if [[ -z "$phase" ]]; then
        echo "zdot_phase_run: phase name required" >&2
        return 1
    fi

    local hooks="${_ZDOT_PHASES[$phase]}"
    if [[ -n "$hooks" ]]; then
        for hook in ${=hooks}; do
            if typeset -f "$hook" > /dev/null; then
                "$hook"
            else
                echo "zdot_phase_run: hook function '$hook' not found for phase '$phase'" >&2
            fi
        done
    fi
}

# List all registered phases with detailed information
# Usage: zdot_phase_list [--verbose|-v]
zdot_phase_list() {
    local verbose=0
    if [[ "$1" == "--verbose" || "$1" == "-v" ]]; then
        verbose=1
    fi

    # Define phase order for organized display
    local -a phase_order
    phase_order=(bootstrap system pre-plugin plugin-load post-plugin after-secrets finalize)

    echo "Registered Phase Hooks:"
    echo ""

    for phase in $phase_order; do
        local hooks="${_ZDOT_PHASES[$phase]}"

        if [[ -n "$hooks" ]]; then
            echo "Phase: $phase"

            local hook_count=0
            for hook in ${=hooks}; do
                ((hook_count++))

                # Get module that registered this hook
                local module="${_ZDOT_HOOK_MODULES[$hook]:-unknown}"

                if [[ $verbose -eq 1 ]]; then
                    # Verbose mode: show if function exists and is defined
                    if typeset -f "$hook" > /dev/null 2>&1; then
                        echo "  ✓ $hook [$module] (defined)"
                    else
                        echo "  ✗ $hook [$module] (NOT defined)"
                    fi
                else
                    # Normal mode: show hook and module
                    echo "  • $hook [$module]"
                fi
            done

            if [[ $verbose -eq 0 ]]; then
                echo "  ($hook_count hook(s))"
            fi
            echo ""
        fi
    done

    # Show any phases not in the standard order
    for phase in ${(k)_ZDOT_PHASES}; do
        if [[ ! " ${phase_order[@]} " =~ " ${phase} " ]]; then
            local hooks="${_ZDOT_PHASES[$phase]}"
            echo "Phase: $phase (custom)"
            for hook in ${=hooks}; do
                local module="${_ZDOT_HOOK_MODULES[$hook]:-unknown}"
                if [[ $verbose -eq 1 ]]; then
                    if typeset -f "$hook" > /dev/null 2>&1; then
                        echo "  ✓ $hook [$module] (defined)"
                    else
                        echo "  ✗ $hook [$module] (NOT defined)"
                    fi
                else
                    echo "  • $hook [$module]"
                fi
            done
            echo ""
        fi
    done

    # Summary
    local total_phases=${#_ZDOT_PHASES[@]}
    echo "Total: $total_phases phase(s) registered"
}

# List hooks organized by module
# Usage: zdot_module_hooks [module-name]
zdot_module_hooks() {
    local target_module="$1"

    # Build a map of module -> hooks
    local -A module_hooks

    for hook in ${(k)_ZDOT_HOOK_MODULES}; do
        local module="${_ZDOT_HOOK_MODULES[$hook]}"

        # Filter by module if specified
        if [[ -n "$target_module" && "$module" != "$target_module" ]]; then
            continue
        fi

        if [[ -z "${module_hooks[$module]}" ]]; then
            module_hooks[$module]="$hook"
        else
            module_hooks[$module]="${module_hooks[$module]} $hook"
        fi
    done

    if [[ -n "$target_module" ]]; then
        echo "Hooks registered by module: $target_module"
    else
        echo "Hooks registered by each module:"
    fi
    echo ""

    # Sort modules alphabetically
    for module in ${(ko)module_hooks}; do
        echo "Module: $module"

        local hooks="${module_hooks[$module]}"
        for hook in ${=hooks}; do
            # Find which phase(s) this hook belongs to
            local phases=""
            for phase in ${(k)_ZDOT_PHASES}; do
                if [[ " ${_ZDOT_PHASES[$phase]} " =~ " ${hook} " ]]; then
                    if [[ -z "$phases" ]]; then
                        phases="$phase"
                    else
                        phases="${phases}, $phase"
                    fi
                fi
            done

            echo "  • $hook → [$phases]"
        done
        echo ""
    done

    if [[ -z "$target_module" ]]; then
        local total_modules=${#module_hooks[@]}
        echo "Total: $total_modules module(s) with registered hooks"
    fi
}
