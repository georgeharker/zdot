#!/usr/bin/env zsh
# zsh-base/hooks: Phase and hook management system
# Provides registration, execution, and introspection for phase-based hooks

# ============================================================================
# Phase Management
# ============================================================================

# Register a hook function to run during a named phase
# Usage: zdot_hook_register <phase-name> <function-name> <context1> [context2 ...]
# Contexts: interactive, noninteractive, login, nonlogin
# Example: zdot_hook_register bootstrap _my_init interactive noninteractive
zdot_hook_register() {
    local phase="$1"
    local func="$2"
    local contexts=("${@:3}")

    if [[ -z "$phase" || -z "$func" ]]; then
        echo "zdot_hook_register: phase and function required" >&2
        return 1
    fi

    if [[ ${#contexts[@]} -eq 0 ]]; then
        echo "zdot_hook_register: at least one context required (interactive, noninteractive, login, nonlogin)" >&2
        return 1
    fi

    # Register hook for each specified context
    for ctx in "${contexts[@]}"; do
        local phase_ctx="${phase}@${ctx}"
        # Initialize phase array if it doesn't exist
        if [[ -z "${_ZDOT_PHASES[$phase_ctx]}" ]]; then
            _ZDOT_PHASES[$phase_ctx]=""
        fi

        # Append function to phase
        if [[ -z "${_ZDOT_PHASES[$phase_ctx]}" ]]; then
            _ZDOT_PHASES[$phase_ctx]="$func"
        else
            _ZDOT_PHASES[$phase_ctx]="${_ZDOT_PHASES[$phase_ctx]} $func"
        fi
    done

    # Track which module registered this hook
    if [[ -n "$_ZDOT_CURRENT_MODULE_NAME" ]]; then
        _ZDOT_HOOK_MODULES[$func]="$_ZDOT_CURRENT_MODULE_NAME"
    fi
}

# Execute all hooks registered for a phase
# Usage: zdot_phase_run <phase-name>
# Automatically determines shell context and merges appropriate hook lists
zdot_phase_run() {
    local phase="$1"

    if [[ -z "$phase" ]]; then
        echo "zdot_phase_run: phase name required" >&2
        return 1
    fi

    # Track that this phase was executed (only if not already in the list)
    if [[ ! " ${_ZDOT_PHASE_EXECUTION_ORDER[@]} " =~ " ${phase} " ]]; then
        _ZDOT_PHASE_EXECUTION_ORDER+=("$phase")
    fi

    # Determine current shell context
    local interactive_ctx="noninteractive"
    [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]] && interactive_ctx="interactive"

    local login_ctx="nonlogin"
    [[ $_ZDOT_IS_LOGIN -eq 1 ]] && login_ctx="login"

    # Collect hooks from both context dimensions
    local interactive_phase_ctx="${phase}@${interactive_ctx}"
    local hooks_interactive="${_ZDOT_PHASES[${interactive_phase_ctx}]}"
    local login_phase_ctx="${phase}@${login_ctx}"
    local hooks_login="${_ZDOT_PHASES[${login_phase_ctx}]}"

    # Merge hook lists (deduplicate)
    local -a all_hooks
    local -A seen_hooks

    # Add interactive context hooks
    for hook in ${=hooks_interactive}; do
        if [[ -z "${seen_hooks[$hook]}" ]]; then
            all_hooks+=("$hook")
            seen_hooks[$hook]=1
        fi
    done

    # Add login context hooks
    for hook in ${=hooks_login}; do
        if [[ -z "${seen_hooks[$hook]}" ]]; then
            all_hooks+=("$hook")
            seen_hooks[$hook]=1
        fi
    done

    # Execute all collected hooks
    for hook in "${all_hooks[@]}"; do
        if typeset -f "$hook" > /dev/null; then
            "$hook"
        else
            echo "zdot_phase_run: hook function '$hook' not found for phase '$phase'" >&2
        fi
    done
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
