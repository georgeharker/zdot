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
typeset -gA _ZDOT_HOOK_PROVIDES      # hook_id -> "phase1 phase2 ..." (space-joined)
typeset -gA _ZDOT_HOOK_OPTIONAL      # hook_id -> 1 if optional
typeset -gA _ZDOT_PHASE_PROVIDERS_BY_CONTEXT  # "context:phase" -> hook_id (context-aware lookup)
typeset -gA _ZDOT_PHASES_PROVIDED    # phase_name -> 1 when actually available at runtime
typeset -gA _ZDOT_HOOKS_EXECUTED     # hook_id -> 1 when executed at runtime
typeset -gA _ZDOT_HOOKS_QUEUED       # hook_id -> 1 when queued for deferred execution (but not yet run)
typeset -g _ZDOT_HOOK_COUNTER=0
typeset -ga _ZDOT_EXECUTION_PLAN          # Ordered array of hook_ids
typeset -ga _ZDOT_EXECUTION_PLAN_DEFERRED # Subset of plan: hook_ids that are deferred
typeset -g _ZDOT_CURRENT_HOOK_FUNC   # Set by hook runner during execution; empty between hooks
typeset -gA _ZDOT_HOOK_NAMES         # hook_id -> user-assigned name label
typeset -gA _ZDOT_HOOK_BY_NAME       # name label -> hook_id
typeset -ga _ZDOT_DEFER_ORDER_PAIRS  # flat: from_name to_name from_name to_name ...
typeset -ga _ZDOT_DEFER_ORDER_WARNINGS      # warnings accumulated during edge injection
typeset -ga _ZDOT_FORCED_DEFERRED_WARNINGS  # warnings for hooks force-deferred due to deferred dependency
typeset -ga _ZDOT_DEFERRED_HOOKS            # hook_ids marked as deferred (skip eager plan)
typeset -gA _ZDOT_ACCEPTED_DEFERRED         # func_name -> "all" or "phase1 phase2 ..." (user-accepted force-deferral)
typeset -gA _ZDOT_HOOK_GROUP                # hook_id -> group name (--group)
typeset -gA _ZDOT_HOOK_PROVIDES_GROUP       # hook_id -> group name this hook provides into (--provides-group)
typeset -gA _ZDOT_HOOK_REQUIRES_GROUP       # hook_id -> group name this hook requires from (--requires-group)
typeset -gA _ZDOT_HOOK_GROUPS               # hook_id -> "group1 group2 ..." (multi-group forward map)
typeset -gA _ZDOT_GROUP_MEMBERS             # group_name -> "hook_id1 hook_id2 ..." (reverse index)
typeset -gA _ZDOT_HOOK_DEFER_ARGS           # hook_id -> flag-set key (see _ZDOT_DEFER_FLAG_NAMES)
typeset -gA _ZDOT_DEFER_FLAG_NAMES          # flag-set key -> display name; extend here to add new defer modes
_ZDOT_DEFER_FLAG_NAMES["--prompt"]="prompt"
_ZDOT_DEFER_FLAG_NAMES["-p"]="prompt"
_ZDOT_DEFER_FLAG_NAMES["--quiet"]="quiet"
_ZDOT_DEFER_FLAG_NAMES["-q"]="quiet"

# ============================================================================
# Acceptance of Force-Deferred Hooks
# ============================================================================

# Mark a hook function as intentionally force-deferred, suppressing warnings.
# Must be called before zdot_build_execution_plan.
# Usage: zdot_accept_deferred <function-name> [<phase>...]
#   With no phases: accepts all force-deferral for this hook function.
#   With phases: accepts only force-deferral caused by those specific phases.
zdot_accept_deferred() {
    local func_name="$1"
    shift
    if [[ -z $func_name ]]; then
        print -u2 "zdot_accept_deferred: missing function name"
        return 1
    fi
    if [[ $# -eq 0 ]]; then
        _ZDOT_ACCEPTED_DEFERRED[$func_name]="all"
    else
        local existing="${_ZDOT_ACCEPTED_DEFERRED[$func_name]:-}"
        if [[ $existing == "all" ]]; then
            return 0  # already fully accepted
        fi
        local phase
        for phase in "$@"; do
            if [[ " $existing " != *" $phase "* ]]; then
                existing="${existing:+$existing }$phase"
            fi
        done
        _ZDOT_ACCEPTED_DEFERRED[$func_name]="$existing"
    fi
}

# ============================================================================
# Hook Registration
# ============================================================================

# Register a hook function with dependency metadata
# Usage: zdot_hook_register <function-name> <context...> [--requires <phase...>] [--requires-tool <tool>] [--provides <phase>] [--provides-tool <tool>] [--optional]
# Sets REPLY to the hook_id on success.
# Contexts: interactive, noninteractive, login, nonlogin
# --provides-tool <tool>  sugar for --provides tool:<tool>
# --requires-tool <tool>  sugar for --requires tool:<tool>
# Multiple --provides / --provides-tool flags are allowed
# Example: zdot_hook_register _my_init interactive --requires xdg-configured --provides my-ready
# Example: zdot_hook_register _brew_install interactive --provides-tool fzf --provides-tool op
zdot_hook_register() {
    # Pre-pass: extract --name and --deferred before positional parsing.
    # These two flags are extracted here rather than in the main parsing loop
    # below because the main loop uses a simple case-in-positional pattern that
    # treats the first non-flag tokens as context names.  If --name or --deferred
    # appeared mixed among the contexts they would be silently treated as context
    # strings.  By stripping them in advance we keep the main loop simple and
    # context-safe while still supporting the flags anywhere in the argument list.
    local hook_name=""
    local hook_deferred=0
    local hook_defer_noquiet=0
    local hook_defer_args
    local -a hook_groups=()
    local hook_provides_group=""
    local hook_requires_group=""
    local -a _raw_args=("$@")
    local -a _filtered_args=()
    local _i=1
    while [[ $_i -le ${#_raw_args[@]} ]]; do
        if [[ ${_raw_args[$_i]} == --name ]]; then
            (( _i++ ))
            hook_name="${_raw_args[$_i]}"
        elif [[ ${_raw_args[$_i]} == --deferred ]]; then
            hook_deferred=1
        elif [[ ${_raw_args[$_i]} == --deferred-prompt ]]; then
            hook_deferred=1
            hook_defer_noquiet=1
            hook_defer_args="--prompt"
        elif [[ ${_raw_args[$_i]} == --group ]]; then
            (( _i++ ))
            hook_groups+=("${_raw_args[$_i]}")
        elif [[ ${_raw_args[$_i]} == --provides-group ]]; then
            (( _i++ ))
            hook_provides_group="${_raw_args[$_i]}"
        elif [[ ${_raw_args[$_i]} == --requires-group ]]; then
            (( _i++ ))
            hook_requires_group="${_raw_args[$_i]}"
        else
            _filtered_args+=("${_raw_args[$_i]}")
        fi
        (( _i++ ))
    done
    set -- "${_filtered_args[@]}"

    local func_name=$1
    shift

    local -a contexts
    local -a requires
    local -a provides
    local optional=0

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
            --requires-tool)
                requires+=("tool:$2")
                shift 2
                ;;
            --provides)
                provides+=($2)
                shift 2
                ;;
            --provides-tool)
                provides+=("tool:$2")
                shift 2
                ;;
            --optional)
                optional=1
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

    # Store name mapping (fall back to func_name if --name not given)
    local _effective_name="${hook_name:-$func_name}"
    if [[ -n "${_ZDOT_HOOK_BY_NAME[$_effective_name]}" ]]; then
        zdot_warn "zdot_hook_register: duplicate hook name '$_effective_name'; skipping registration"
        return 1
    fi
    _ZDOT_HOOK_NAMES[$hook_id]="$_effective_name"
    _ZDOT_HOOK_BY_NAME[$_effective_name]="$hook_id"

    # Store hook metadata
    _ZDOT_HOOKS[$hook_id]=$func_name
    _ZDOT_HOOK_CONTEXTS[$hook_id]="${contexts[*]}"
    _ZDOT_HOOK_REQUIRES[$hook_id]="${requires[*]}"
    _ZDOT_HOOK_PROVIDES[$hook_id]="${provides[*]}"
    _ZDOT_HOOK_OPTIONAL[$hook_id]=$optional
    [[ $hook_deferred -eq 1 ]] && _ZDOT_DEFERRED_HOOKS+=($hook_id)
    [[ $hook_deferred -eq 1 && $hook_defer_noquiet -eq 1 ]] && _ZDOT_HOOK_DEFER_ARGS[$hook_id]="$hook_defer_args"
    if [[ ${#hook_groups[@]} -gt 0 ]]; then
        _ZDOT_HOOK_GROUP[$hook_id]="${hook_groups[1]}"
        local _hg
        for _hg in "${hook_groups[@]}"; do
            _ZDOT_HOOK_GROUPS[$hook_id]+=" $_hg"
            _ZDOT_HOOK_GROUPS[$hook_id]="${_ZDOT_HOOK_GROUPS[$hook_id]# }"
            _ZDOT_GROUP_MEMBERS[$_hg]+=" $hook_id"
            _ZDOT_GROUP_MEMBERS[$_hg]="${_ZDOT_GROUP_MEMBERS[$_hg]# }"
        done
    fi
    [[ -n $hook_provides_group ]] && _ZDOT_HOOK_PROVIDES_GROUP[$hook_id]="$hook_provides_group"
    [[ -n $hook_requires_group ]] && _ZDOT_HOOK_REQUIRES_GROUP[$hook_id]="$hook_requires_group"

    # Register phase provider (context-aware)
    if [[ ${#provides[@]} -gt 0 ]]; then
        local -a phases_to_register=()

        for p in ${provides[@]}; do
            local is_tool_phase=0
            [[ $p == tool:* ]] && is_tool_phase=1

            local skip_phase=0
            for new_ctx in ${contexts[@]}; do
                local ctx_key="${new_ctx}:${p}"

                if [[ -n ${_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]} ]]; then
                    local conflicting_hook=${_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]}
                    if [[ $is_tool_phase -eq 1 ]]; then
                        # Tool phases: first registered wins; warn and skip
                        zdot_warn "zdot_hook_register: phase '$p' already provided by '${_ZDOT_HOOKS[$conflicting_hook]}' in context '$new_ctx'; skipping '$func_name'"
                        skip_phase=1
                        break
                    else
                        zdot_error "zdot_hook_register: ERROR: Multiple hooks provide phase '$p' in context '$new_ctx'"
                        zdot_error "  Previous: ${_ZDOT_HOOKS[$conflicting_hook]}"
                        zdot_error "  Current: $func_name"
                        return 1
                    fi
                fi
            done

            [[ $skip_phase -eq 0 ]] && phases_to_register+=($p)
        done

        # Register non-conflicting phases for each context
        for p in ${phases_to_register[@]}; do
            for ctx in ${contexts[@]}; do
                local ctx_key="${ctx}:${p}"
                _ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]=$hook_id
            done
        done
    fi
    
    # Track which module registered this hook
    if [[ -n "$_ZDOT_CURRENT_MODULE_NAME" ]]; then
        _ZDOT_HOOK_MODULES[$func_name]="$_ZDOT_CURRENT_MODULE_NAME"
    fi
    REPLY=$hook_id
}

# Register declarative ordering constraints between named hooks
# Usage: zdot_defer_order <name-A> <name-B> [name-C ...]
# Generates all pairwise A→B, A→C, B→C pairs (full ordering chain)
# Must be called before zdot_build_execution_plan
zdot_defer_order() {
    local -a names=("$@")
    if [[ ${#names[@]} -lt 2 ]]; then
        zdot_error "zdot_defer_order: requires at least 2 hook names"
        return 1
    fi
    local i j
    for (( i=1; i<${#names[@]}; i++ )); do
        for (( j=i+1; j<=${#names[@]}; j++ )); do
            _ZDOT_DEFER_ORDER_PAIRS+=("${names[$i]}" "${names[$j]}")
        done
    done
}

# ============================================================================
# Dependency Resolution (Topological Sort)
# ============================================================================

# Helper: Check if a phase has a provider in any of the given contexts
# Usage: _zdot_has_provider_in_contexts <phase> <context1> <context2> ...
# Returns: 0 if provider exists, 1 otherwise
_zdot_has_provider_in_contexts() {
    local phase="$1"
    shift
    local -a contexts=("$@")
    
    for ctx in ${contexts[@]}; do
        local ctx_key="${ctx}:${phase}"
        if [[ -n ${_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]} ]]; then
            return 0
        fi
    done
    
    return 1
}

# Build execution plan using topological sort (Kahn's algorithm)
# Usage: zdot_build_execution_plan
# Determines current shell context and builds dependency-ordered execution plan
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
            # Check if phase is promised or has a provider hook in current contexts
            if ! _zdot_has_provider_in_contexts "$phase" "${current_contexts[@]}"; then
                # Required phase has no provider in current context
                if [[ ${_ZDOT_HOOK_OPTIONAL[$hook_id]} == 1 ]]; then
                    skipped_hooks+=("${_ZDOT_HOOKS[$hook_id]} (missing: $phase)")
                    degree=-1  # Mark as skipped
                    break
                else
                    zdot_error "zdot_build_execution_plan: Hook '${_ZDOT_HOOKS[$hook_id]}' requires phase '$phase' but no hook provides it in current context"
                    return 1
                fi
            fi
            
            (( degree++ ))
            # Build adjacency list: phase -> hooks that depend on it
            adjacency_list[$phase]+=" $hook_id"
        done
        
        # Skip if marked as skipped
        if [[ $degree -eq -1 ]]; then
            continue
        fi
        
        in_degree[$hook_id]=$degree
        
        if [[ $degree -eq 0 ]]; then
            zero_in_degree+=($hook_id)
        fi
    done

    # ── Defer-order edge injection ──
    #
    # zdot_defer_order(A, B) says "run hook A before hook B" without
    # coupling them through a shared phase.  Internally this is
    # implemented by injecting a synthetic DAG edge A→B into the
    # scheduler's graph before Kahn's algorithm runs.
    #
    # Before injecting we must verify three safety conditions:
    #   1. Contradiction: B→A already exists in the real DAG (would
    #      create a cycle — reject).
    #   2. Redundancy: A→B is already implied by a real phase-provider
    #      edge (injection would be a no-op — skip).
    #   3. Synthetic cycle: the new A→B edge, combined with previously
    #      injected synthetic edges, would form a cycle in the
    #      synthetic-only subgraph (reject).
    #
    # `edge_set` captures every real DAG edge (provider_hook→dependent_hook)
    # so conditions 1 and 2 can be checked in O(1).
    local -A edge_set=()
    for _hid in ${(k)in_degree}; do
        local _reqs=(${=_ZDOT_HOOK_REQUIRES[$_hid]})
        for _ph in $_reqs; do
            # Find who provides this phase in current context
            for _ctx in "${current_contexts[@]}"; do
                local _prov="${_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[${_ctx}:${_ph}]}"
                if [[ -n "$_prov" ]]; then
                    edge_set["${_prov}:${_hid}"]=1
                fi
            done
        done
    done

    # Iterative DFS cycle detector for the synthetic-edge-only subgraph.
    #
    # `_doo_adj` is an associative array whose keys are hook IDs and
    # whose values are space-separated lists of successor hook IDs
    # reachable via synthetic defer-order edges only (real DAG edges
    # are NOT included).
    #
    # Returns 0 (true) if a directed path from `_src` to `_dst` exists
    # in `_doo_adj`; returns 1 otherwise.
    #
    # Called before injecting each new synthetic A→B edge to check
    # whether B→A already exists in the synthetic subgraph.  If it
    # does, adding A→B would form a cycle and the edge is rejected.
    # Real DAG contradictions are caught separately via `edge_set`.
    local -A _doo_adj=()  # hook_id -> space-joined hook_ids (defer-order-only graph)
    _zdot_doo_has_path() {
        local _src="$1" _dst="$2"
        local -a _stack=("$_src")
        local -A _visited=()
        while [[ ${#_stack[@]} -gt 0 ]]; do
            local _cur="${_stack[-1]}"
            _stack=("${_stack[@]:0:${#_stack[@]}-1}")
            [[ -n "${_visited[$_cur]}" ]] && continue
            _visited[$_cur]=1
            [[ "$_cur" == "$_dst" ]] && return 0
            local _nbrs=(${=_doo_adj[$_cur]})
            for _n in $_nbrs; do _stack+=("$_n"); done
        done
        return 1
    }

    local _pi=1
    while [[ $_pi -lt ${#_ZDOT_DEFER_ORDER_PAIRS[@]} ]]; do
        local _from_name="${_ZDOT_DEFER_ORDER_PAIRS[$_pi]}"
        local _to_name="${_ZDOT_DEFER_ORDER_PAIRS[$(( _pi + 1 ))]}"
        (( _pi += 2 ))

        local _hid_a="${_ZDOT_HOOK_BY_NAME[$_from_name]}"
        local _hid_b="${_ZDOT_HOOK_BY_NAME[$_to_name]}"

        # Skip if either hook is not active in current context
        if [[ -z "${in_degree[$_hid_a]+x}" || -z "${in_degree[$_hid_b]+x}" ]]; then
            _ZDOT_DEFER_ORDER_WARNINGS+=("zdot_defer_order: '$_from_name'→'$_to_name': one or both hooks not active in current context; skipping")
            continue
        fi

        # Contradiction: B→A already in DAG
        if [[ -n "${edge_set[${_hid_b}:${_hid_a}]}" ]]; then
            _ZDOT_DEFER_ORDER_WARNINGS+=("zdot_defer_order: '$_from_name'→'$_to_name': CONTRADICTS existing DAG edge '$_to_name'→'$_from_name'; skipping")
            continue
        fi

        # Redundant: A→B already in DAG
        if [[ -n "${edge_set[${_hid_a}:${_hid_b}]}" ]]; then
            _ZDOT_DEFER_ORDER_WARNINGS+=("zdot_defer_order: '$_from_name'→'$_to_name': already implied by existing DAG; skipping (ok)")
            continue
        fi

        # Cycle check in defer-order-only graph
        if _zdot_doo_has_path "$_hid_b" "$_hid_a"; then
            _ZDOT_DEFER_ORDER_WARNINGS+=("zdot_defer_order: '$_from_name'→'$_to_name': would create cycle in defer-order constraints; skipping")
            continue
        fi

        # Inject synthetic edge: use A's first provided phase as the bridge,
        # or create a synthetic phase name if A provides nothing
        local _provided_phases_a=(${=_ZDOT_HOOK_PROVIDES[$_hid_a]})
        local _bridge_phase
        if [[ ${#_provided_phases_a[@]} -gt 0 ]]; then
            _bridge_phase="${_provided_phases_a[1]}"
        else
            _bridge_phase="_defer_order_${_hid_a}"
        fi

        # Add edge to adjacency list and increment in_degree of B
        adjacency_list[$_bridge_phase]+=" $_hid_b"
        (( in_degree[$_hid_b]++ ))

        # Track in defer-order-only graph for future cycle checks
        _doo_adj[$_hid_a]+=" $_hid_b"
        edge_set["${_hid_a}:${_hid_b}"]=1
    done

    # Emit accumulated warnings
    for _w in "${_ZDOT_DEFER_ORDER_WARNINGS[@]}"; do
        zdot_warn "$_w"
    done

    # Kahn's algorithm for topological sort
    # This processes all hooks that have dependencies on provider hooks
    while [[ ${#zero_in_degree} -gt 0 ]]; do
        # Pop from zero_in_degree queue
        local current_hook=${zero_in_degree[1]}
        zero_in_degree=("${zero_in_degree[@]:1}")
        
        # Add to execution order
        execution_order+=($current_hook)
        
        # Get phases this hook provides
        local -a provided_phases=(${=_ZDOT_HOOK_PROVIDES[$current_hook]})

        for provided_phase in $provided_phases; do
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
        done

        # Drain synthetic defer-order bridge phase.
        #
        # When zdot_defer_order(A, B) is recorded, the edge injector above
        # routes the ordering constraint through a bridge phase named
        # `_defer_order_<hid_a>`.  The bridge acts as a phantom "provided
        # phase" that B depends on, so B's in-degree is decremented when
        # A completes — exactly like a real phase dependency.
        #
        # However, if hook A provides NO real phases, the phase-processing
        # loop above never visits `_defer_order_<hid_a>`, so B's in-degree
        # is never decremented and B would be permanently stuck in the
        # queue.  This block explicitly drains the bridge phase for every
        # hook after it is processed, ensuring B is unblocked whether or
        # not A provides any real phases.
        local _synthetic_phase="_defer_order_${current_hook}"
        if [[ -n "${adjacency_list[$_synthetic_phase]}" ]]; then
            local _synthetic_deps=(${=adjacency_list[$_synthetic_phase]})
            for dep_hook in $_synthetic_deps; do
                (( in_degree[$dep_hook]-- ))
                if [[ ${in_degree[$dep_hook]} -eq 0 ]]; then
                    zero_in_degree+=($dep_hook)
                fi
            done
        fi
    done
    
    # Check for cycles
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

    # Build set of deferred hook_ids in the plan
    _ZDOT_EXECUTION_PLAN_DEFERRED=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        if [[ ${_ZDOT_DEFERRED_HOOKS[(Ie)$hook_id]} -gt 0 ]]; then
            _ZDOT_EXECUTION_PLAN_DEFERRED+=($hook_id)
        fi
    done

    # Policy: if a non-deferred hook depends on a phase that is only
    # provided by a deferred hook, it must itself be deferred ("force-
    # deferred").  This propagates transitively: force-deferring hook X
    # may make X's provided phases become deferred, which can then force-
    # defer hook Y, and so on.  A fixed-point loop below computes the
    # full transitive closure.
    #
    # `phase_provider_reason` maps each phase that will be provided after
    # the prompt (by a deferred hook) to a reason string:
    #
    #   "explicit" — provided by a hook the user explicitly marked
    #                --deferred (intentional; no warning is emitted to
    #                the user, since this is an expected dependency)
    #
    #   "forced"   — provided by a hook that was itself force-deferred
    #                because it depended on an explicit-deferred phase
    #                (unintended transitive chain; a warning is emitted
    #                unless zdot_accept_deferred was called for that
    #                func+phase combination to pre-acknowledge it)
    #
    # Seeded below from the initial deferred set before the loop starts.
    _ZDOT_FORCED_DEFERRED_WARNINGS=()
    local -A phase_provider_reason
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        for phase in ${=_ZDOT_HOOK_PROVIDES[$hook_id]}; do
            if [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -gt 0 ]]; then
                if [[ ${_ZDOT_DEFERRED_HOOKS[(Ie)$hook_id]} -gt 0 ]]; then
                    phase_provider_reason[$phase]="explicit"
                else
                    phase_provider_reason[$phase]="forced"
                fi
            fi
        done
    done

    # Fixed-point propagation loop.
    #
    # On each pass we scan every non-deferred hook.  If any of its
    # required phases appears in `phase_provider_reason` (i.e., will be
    # provided late by some deferred hook), that hook is force-deferred:
    #   • its own provided phases are added to `phase_provider_reason`
    #     with reason "forced"
    #   • `changed` is set to 1 so the loop reruns
    #
    # The loop repeats until a full pass produces no new force-deferrals
    # (fixed point / transitive closure).  This is necessary because
    # force-deferring X may expose new late-provided phases that in turn
    # force-defer Y, which may expose more, and so on.
    #
    # The `reason` value controls user-visible behaviour:
    #   "explicit" → silent (user knowingly created the dependency)
    #   "forced"   → warning emitted (unexpected late dependency chain)
    #                unless zdot_accept_deferred pre-acknowledged it
    local changed=1
    while [[ $changed -eq 1 ]]; do
        changed=0
        for hook_id in $_ZDOT_EXECUTION_PLAN; do
            # Already deferred — skip
            [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -gt 0 ]] && continue
            # Check if any required phase is provided only by a deferred hook
            for phase in ${=_ZDOT_HOOK_REQUIRES[$hook_id]}; do
                if [[ ${phase_provider_reason[$phase]+x} ]]; then
                    local reason="${phase_provider_reason[$phase]}"
                    # Force-defer this hook
                    _ZDOT_EXECUTION_PLAN_DEFERRED+=($hook_id)
                    # Propagate: phases this hook provides are now "forced" (transitively)
                    for provided in ${=_ZDOT_HOOK_PROVIDES[$hook_id]}; do
                        phase_provider_reason[$provided]="forced"
                    done
                    # Only warn if the triggering phase came from a force-deferred hook
                    # (not an explicit --deferred tool dependency — that is expected/silent)
                    if [[ $reason == "forced" ]]; then
                        local func_name="${_ZDOT_HOOKS[$hook_id]}"
                        # Check if the user has accepted this force-deferral
                        local _accepted=0
                        if [[ ${_ZDOT_ACCEPTED_DEFERRED[$func_name]+x} ]]; then
                            local _acceptance="${_ZDOT_ACCEPTED_DEFERRED[$func_name]}"
                            if [[ $_acceptance == "all" ]] || [[ " $_acceptance " == *" $phase "* ]]; then
                                _accepted=1
                            fi
                        fi
                        if [[ $_accepted -eq 0 ]]; then
                            local msg="zdot: WARNING: Hook '$func_name' requires deferred phase '$phase'; it has been force-deferred"
                            zdot_warn "$msg"
                            if [[ ${_ZDOT_DEFERRED_HOOKS[(Ie)$hook_id]} -eq 0 ]]; then
                                _ZDOT_FORCED_DEFERRED_WARNINGS+=("$msg")
                            fi
                        fi
                    fi
                    changed=1
                    break
                fi
            done
        done
    done

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

# Verify that declared tools are available on PATH (runtime post-hoc check)
# Usage: zdot_verify_tools <tool1> [tool2 ...]
# Warns for each tool not found; does not affect scheduling
zdot_verify_tools() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" &>/dev/null; then
            zdot_warn "zdot_verify_tools: tool '$tool' not found on PATH"
        fi
    done
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
    local -a provides=(${=_ZDOT_HOOK_PROVIDES[$hook_id]})

    # Execute the hook function
    if typeset -f "$func" > /dev/null; then
        zdot_verbose "zdot: hooks: run: $func"
        _ZDOT_CURRENT_HOOK_FUNC=$func
        if $func; then
            local _rc=$?
            _ZDOT_CURRENT_HOOK_FUNC=

            _ZDOT_HOOKS_EXECUTED[$hook_id]=1

            # Mark each provided phase as provided
            for phase in $provides; do
                _ZDOT_PHASES_PROVIDED[$phase]=1
                zdot_verbose "zdot: hooks: provided: $phase"

                # Call stop callback if provided
                if [[ -n $stop_callback ]] && $stop_callback "$phase"; then
                    return 2
                fi
            done
            return 0
        else
            local _rc=$?
            _ZDOT_CURRENT_HOOK_FUNC=
            _ZDOT_HOOKS_EXECUTED[$hook_id]=1
            zdot_error "${function_name}: Hook '$func' failed (exit code: $_rc)"
            return 1
        fi
    else
        _ZDOT_HOOKS_EXECUTED[$hook_id]=1
        zdot_error "${function_name}: Hook function '$func' not found"
        return 1
    fi
}

# Wrapper used when running a deferred hook post-prompt.
#
# Each deferred hook is scheduled via `zdot_defer` (which runs code
# asynchronously after the prompt is displayed).  Instead of scheduling
# the hook function directly, the scheduler schedules this wrapper.
#
# After the wrapped hook finishes executing, the wrapper immediately
# calls `_zdot_run_deferred_phase_check`.  That call may detect that
# the hook's completion has satisfied the requirements of the *next*
# deferred hook in the plan and dispatch it.  The result is a chain-
# reaction: each deferred hook's completion triggers the dispatch of
# the next eligible one, so deferred hooks run in dependency order
# without needing a central polling loop.
#
# The chain always continues regardless of the hook's exit code:
#   0 — success (hook ran cleanly)
#   2 — hook was already executed / skipped (not a failure)
#   other — hook reported an error; phases it was supposed to provide
#            will be absent, so downstream hooks will stall and the
#            stall detector in `_zdot_run_deferred_phase_check` will
#            report the missing phases.  We still call the check so
#            that any independent branches can still make progress.
_zdot_deferred_hook_wrapper() {
    local hook_id=$1
    unset "_ZDOT_HOOKS_QUEUED[$hook_id]"
    local _hw_label="${_ZDOT_HOOKS[$hook_id]}"
    local _hw_name="${_ZDOT_HOOK_NAMES[$hook_id]}"
    [[ -n "$_hw_name" ]] && _hw_label+=" [${_hw_name}]"
    _ZDOT_DEFERRED_CURRENT_HOOK="$_hw_label"
    _zdot_deferred_progress_print "$_hw_label"
    _zdot_execute_hook "$hook_id"
    _ZDOT_DEFERRED_CURRENT_HOOK=''
    _zdot_run_deferred_phase_check
}

# Return 0 if every phase required by hook_id is present in
# `_ZDOT_PHASES_PROVIDED`, 1 otherwise.
_zdot_hook_requirements_met() {
    local hook_id=$1
    local requires=(${=_ZDOT_HOOK_REQUIRES[$hook_id]})
    local req
    for req in $requires; do
        if [[ ${+_ZDOT_PHASES_PROVIDED[$req]} -eq 0 ]]; then
            return 1
        fi
    done
    return 0
}

# Scan the deferred subset of the execution plan and dispatch any hook
# whose requirements are now fully satisfied.
#
# Only hooks in `_ZDOT_EXECUTION_PLAN_DEFERRED` are considered; the
# eager (non-deferred) plan has already completed by this point.
#
# A hook is skipped if:
#   • it is already in `_ZDOT_HOOKS_EXECUTED` (already ran), or
#   • it is already in `_ZDOT_HOOKS_QUEUED` (already dispatched but
#     not yet finished — avoids double-scheduling).
#
# A hook is dispatched (via `zdot_defer -q`) when every phase listed
# in its `requires` set is present in `_ZDOT_PHASES_PROVIDED`
# (checked via `_zdot_hook_requirements_met`).
#
# Called in two places:
#   1. Once from `.zshrc` immediately after `zdot_execute_all` returns,
#      to kick off the first wave of deferred hooks.
#   2. From `_zdot_deferred_hook_wrapper` after each hook finishes,
#      to kick off subsequent waves (chain-reaction dispatch).
_zdot_run_deferred_phase_check() {
    local hook_id
    local dispatched=0
    local -a pending_hooks=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        # Only process deferred hooks
        if [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -eq 0 ]]; then
            continue
        fi

        # Already ran — skip
        if [[ ${+_ZDOT_HOOKS_EXECUTED[$hook_id]} -eq 1 ]]; then
            continue
        fi

        # Already queued but not yet run — skip to prevent duplicate dispatch
        if [[ ${+_ZDOT_HOOKS_QUEUED[$hook_id]} -eq 1 ]]; then
            continue
        fi

        # Dispatch only when all required phases are available
        if ! _zdot_hook_requirements_met "$hook_id"; then
            pending_hooks+=("$hook_id")
            continue
        fi

        dispatched=$(( dispatched + 1 ))
        _ZDOT_HOOKS_QUEUED[$hook_id]=1
        local _hw_label="${_ZDOT_HOOKS[$hook_id]}"
        local _hw_name="${_ZDOT_HOOK_NAMES[$hook_id]}"
        [[ -n "$_hw_name" ]] && _hw_label+=" [${_hw_name}]"
        local -a _defer_extra=(-q)
        if [[ -n "${_ZDOT_HOOK_DEFER_ARGS[$hook_id]+set}" ]]; then
            local _defer_args="${_ZDOT_HOOK_DEFER_ARGS[$hook_id]}"
            _defer_extra=(${_defer_args:+${(z)_defer_args}})
        fi
        zdot_defer "${_defer_extra[@]}" --label "$_hw_label" _zdot_deferred_hook_wrapper "$hook_id"
    done

    # Stall detection: if nothing was dispatched this round but hooks are still
    # waiting, their required phases will never arrive — report an error.
    # Guard against false positives: if hooks are still queued (in-flight), the
    # required phases may yet be provided once those hooks complete.
    if [[ $dispatched -eq 0 && ${#pending_hooks} -gt 0 && ${#_ZDOT_HOOKS_QUEUED} -eq 0 ]]; then
        _ZDOT_DEFERRED_ACTIVE=0
        if [[ -o zle ]]; then
            local _zdot_flush_fd
            exec {_zdot_flush_fd}</dev/null
            zle -F $_zdot_flush_fd _zdot_flush_handler
        fi
        zdot_error "_zdot_run_deferred_phase_check: deferred hooks are stalled" \
            "(no progress made; the following hooks have unmet requirements" \
            "that will never be provided):"
        local hook_label hook_name req
        local -a missing_phases
        for hook_id in $pending_hooks; do
            hook_label="${_ZDOT_HOOKS[$hook_id]}"
            hook_name="${_ZDOT_HOOK_NAMES[$hook_id]}"
            [[ -n "$hook_name" ]] && hook_label+=" [${hook_name}]"
            missing_phases=()
            for req in ${=_ZDOT_HOOK_REQUIRES[$hook_id]}; do
                if [[ ${+_ZDOT_PHASES_PROVIDED[$req]} -eq 0 ]]; then
                    missing_phases+=("$req")
                fi
            done
            zdot_error "  hook '${hook_label}': waiting for phase(s): ${missing_phases[*]}"
        done
    fi

    # Secondary stall detection: hooks whose requirements ARE met but which are
    # neither queued nor executed — these would be silently stuck (e.g. if a
    # bug incorrectly marks a hook as executed before it runs, or the hook
    # falls through the loop without being dispatched for an unknown reason).
    local -a ready_but_stuck=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -eq 0 ]] && continue
        [[ ${+_ZDOT_HOOKS_EXECUTED[$hook_id]} -eq 1 ]] && continue
        [[ ${+_ZDOT_HOOKS_QUEUED[$hook_id]} -eq 1 ]] && continue
        _zdot_hook_requirements_met "$hook_id" || continue
        # Requirements met, not queued, not executed — it should have been dispatched
        # but wasn't (possibly on a previous call to this function that was interrupted).
        ready_but_stuck+=("$hook_id")
    done
    if [[ ${#ready_but_stuck} -gt 0 && $dispatched -eq 0 && ${#_ZDOT_HOOKS_QUEUED} -eq 0 ]]; then
        _ZDOT_DEFERRED_ACTIVE=0
        if [[ -o zle ]]; then
            local _zdot_flush_fd
            exec {_zdot_flush_fd}</dev/null
            zle -F $_zdot_flush_fd _zdot_flush_handler
        fi
        zdot_error "_zdot_run_deferred_phase_check: the following hooks have met" \
            "requirements but were never dispatched (logic bug):"
        for hook_id in $ready_but_stuck; do
            local hook_label="${_ZDOT_HOOKS[$hook_id]}"
            local hook_name="${_ZDOT_HOOK_NAMES[$hook_id]}"
            [[ -n "$hook_name" ]] && hook_label+=" [${hook_name}]"
            zdot_error "  hook '${hook_label}'"
        done
    fi

    # Normal completion: nothing dispatched, nothing queued, nothing pending —
    # the deferred queue has fully drained.
    if [[ $dispatched -eq 0 && ${#pending_hooks} -eq 0 && ${#_ZDOT_HOOKS_QUEUED} -eq 0 ]]; then
        # Auto-dispatch the 'finally' group on first full drain.
        # Hooks that declared --requires-group finally are collected in
        # _ZDOT_GROUP_MEMBERS[finally]; execute any that haven't run yet.
        if [[ -n "${_ZDOT_GROUP_MEMBERS[finally]}" ]]; then
            local _finally_hook_id
            for _finally_hook_id in ${=_ZDOT_GROUP_MEMBERS[finally]}; do
                if [[ -z ${_ZDOT_HOOKS_EXECUTED[$_finally_hook_id]} ]]; then
                    _zdot_execute_hook "$_finally_hook_id" "_zdot_run_deferred_phase_check"
                fi
            done
        fi
        _ZDOT_DEFERRED_ACTIVE=0
        if [[ -o zle ]]; then
            local _zdot_flush_fd
            exec {_zdot_flush_fd}</dev/null
            zle -F $_zdot_flush_fd _zdot_flush_handler
        fi
    fi
}

# Run every hook in the eager (non-deferred) execution plan in dependency
# order.  This is the primary entry point for shell initialisation and is
# called once from `.zshrc` after `zdot_build_execution_plan` has produced
# `_ZDOT_EXECUTION_PLAN`.
#
# Deferred hooks are intentionally skipped here: their dispatch is managed
# separately by `_zdot_run_deferred_phase_check`, which is called by the
# caller immediately after this function returns.  That keeps the eager and
# deferred dispatch paths cleanly separated.
#
# Each hook is delegated to `_zdot_execute_hook`, which handles function-
# existence checks, phase marking, and `_ZDOT_HOOKS_EXECUTED` bookkeeping.
# Any hook that has already been executed is skipped so this function is
# safe to call after a partial run.
#
# Returns 1 if one or more hooks fail; otherwise 0.
zdot_execute_all() {
    if [[ ${#_ZDOT_EXECUTION_PLAN} -eq 0 ]]; then
        zdot_error "zdot_execute_all: ERROR: No execution plan. Call zdot_build_execution_plan first."
        return 1
    fi
    
    local executed=0
    local failed=0
    
    zdot_verbose "zdot: hooks: executing plan (${#_ZDOT_EXECUTION_PLAN} hooks)"
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        # Skip if this hook was already executed
        if [[ -n ${_ZDOT_HOOKS_EXECUTED[$hook_id]} ]]; then
            continue
        fi

        # Skip deferred hooks — they are dispatched post-prompt
        if [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -gt 0 ]]; then
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

    # Detect eager hooks that were in the plan but never ran.
    # This can happen when a hook's in-degree never reaches zero due to a
    # bug in the dependency graph (e.g. a cycle that Kahn's algorithm could
    # not resolve, or a plan that was built with missing providers that
    # slipped past the earlier checks).
    local -a unexecuted_eager=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        # Deferred hooks are handled separately — skip them here
        if [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -gt 0 ]]; then
            continue
        fi
        if [[ -z ${_ZDOT_HOOKS_EXECUTED[$hook_id]} ]]; then
            unexecuted_eager+=("${_ZDOT_HOOKS[$hook_id]}")
        fi
    done
    if [[ ${#unexecuted_eager[@]} -gt 0 ]]; then
        zdot_error "zdot_execute_all: The following eager hooks were in the plan but never ran (possible dependency cycle or missing provider):"
        for _ue in "${unexecuted_eager[@]}"; do
            zdot_error "  - $_ue"
        done
        return 1
    fi

    zdot_verbose "zdot: hooks: done ($executed executed)"

    # Kick off the deferred hook DAG — runs after the prompt is first drawn.
    # Mark deferred logging as active so log functions route output through ZLE.
    _ZDOT_DEFERRED_ACTIVE=1
    _ZDOT_DEFERRED_SHOWN=0
    zdot_defer -q --label "<run deferred phases>" _zdot_run_deferred_phase_check

    return 0
}

# ============================================================================
# Introspection and Debugging
# ============================================================================


