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
 typeset -gA _ZDOT_HOOK_REQUIRES_CONTEXTS # "hook_id:phase" -> "ctx1 ctx2 ..." (absent = all contexts)
 typeset -gA _ZDOT_PHASES_PROVIDED    # phase_name -> 1 when actually available at runtime
 typeset -gA _ZDOT_HOOKS_EXEC_RESULT       # hook_id -> exit code for every attempted hook (0=ok, N=failed, 'missing'=fn not found)
 typeset -gA _ZDOT_HOOKS_QUEUED       # hook_id -> 1 when queued for deferred execution (but not yet run)
typeset -g _ZDOT_HOOK_COUNTER=0
typeset -ga _ZDOT_EXECUTION_PLAN          # Ordered array of hook_ids
typeset -ga _ZDOT_EXECUTION_PLAN_DEFERRED # Subset of plan: hook_ids that are deferred
typeset -g _ZDOT_CURRENT_HOOK_FUNC   # Set by hook runner during execution; empty between hooks
typeset -gA _ZDOT_HOOK_NAMES         # hook_id -> user-assigned name label
typeset -gA _ZDOT_HOOK_BY_NAME       # name label -> hook_id
typeset -ga _ZDOT_DEFER_ORDER_DEPENDENCIES  # flat stride-3: ctx_spec from_name to_name ctx_spec from_name to_name ...
typeset -ga _ZDOT_DEFER_ORDER_WARNINGS      # warnings accumulated during edge injection
typeset -ga _ZDOT_FORCED_DEFERRED_WARNINGS  # warnings for hooks force-deferred due to deferred dependency
typeset -ga _ZDOT_DEFERRED_HOOKS            # hook_ids marked as deferred (skip eager plan)
typeset -gA _ZDOT_ACCEPTED_DEFERRED         # func_name -> "all" or "phase1 phase2 ..." (user-allowed force-deferral)
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
typeset -ga _ZDOT_DEFER_CMDS            # [N] = command string submitted
typeset -ga _ZDOT_DEFER_HOOKS           # [N] = hook_func that submitted it (or "?" if outside hook)
typeset -ga _ZDOT_DEFER_DELAYS          # [N] = delay in seconds (0 if none)
typeset -ga _ZDOT_DEFER_SPECS           # [N] = human-readable spec name (plugins), "__sentinel__", or ""
typeset -ga _ZDOT_DEFER_LABELS          # [N] = explicit --label override (or "" if none)
typeset -g  _ZDOT_DEFER_COUNTER=0

# ============================================================================
# Acceptance of Force-Deferred Hooks
# ============================================================================

# Mark a hook function as intentionally force-deferred, suppressing warnings.
# Must be called before zdot_build_execution_plan.
# Usage: zdot_allow_defer <function-name> [<phase>...]
#   With no phases: accepts all force-deferral for this hook function.
#   With phases: accepts only force-deferral caused by those specific phases.
zdot_allow_defer() {
    local func_name="$1"
    shift
    if [[ -z $func_name ]]; then
        print -u2 "zdot_allow_defer: missing function name"
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
# Usage: zdot_register_hook <function-name> <context...> [--requires <phase...>] [--requires-tool <tool>] [--provides <phase>] [--provides-tool <tool>] [--optional]
# Sets REPLY to the hook_id on success.
# Contexts: interactive, noninteractive, login, nonlogin
# --provides-tool <tool>  sugar for --provides tool:<tool>
# --requires-tool <tool>  sugar for --requires tool:<tool>
# Multiple --provides / --provides-tool flags are allowed
# Example: zdot_register_hook _my_init interactive --requires xdg-configured --provides my-ready
# Example: zdot_register_hook _brew_install interactive --provides-tool fzf --provides-tool op
zdot_register_hook() {
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
        zdot_error "zdot_register_hook: function name required"
        return 1
    fi

    if [[ ${#contexts[@]} -eq 0 ]]; then
        zdot_error "zdot_register_hook: at least one context required (interactive, noninteractive, login, nonlogin)"
        return 1
    fi
    
    # Generate unique hook ID
    (( _ZDOT_HOOK_COUNTER++ ))
    local hook_id="hook_${_ZDOT_HOOK_COUNTER}"

    # Store name mapping (fall back to func_name if --name not given)
    local _effective_name="${hook_name:-$func_name}"
    if [[ -n "${_ZDOT_HOOK_BY_NAME[$_effective_name]}" ]]; then
        _zdot_internal_warn "zdot_register_hook: duplicate hook name '$_effective_name'; skipping registration"
        REPLY="${_ZDOT_HOOK_BY_NAME[$_effective_name]}"
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
    if [[ -n $hook_provides_group ]]; then
        _ZDOT_HOOK_PROVIDES_GROUP[$hook_id]="$hook_provides_group"
        _ZDOT_GROUP_MEMBERS[$hook_provides_group]+=" $hook_id"
        _ZDOT_GROUP_MEMBERS[$hook_provides_group]="${_ZDOT_GROUP_MEMBERS[$hook_provides_group]# }"
    fi
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
                        _zdot_internal_warn "zdot_register_hook: phase '$p' already provided by '${_ZDOT_HOOKS[$conflicting_hook]}' in context '$new_ctx'; skipping '$func_name'"
                        skip_phase=1
                        break
                    else
                        zdot_error "zdot_register_hook: ERROR: Multiple hooks provide phase '$p' in context '$new_ctx'"
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
# Usage: zdot_defer_order [--context <ctx>] <name-A> <name-B> [name-C ...]
# Generates all pairwise A→B, A→C, B→C pairs (full ordering chain)
# --context <ctx>  Only apply this ordering in the given context (e.g. interactive).
#                  If omitted, the ordering applies in every context where both hooks are active.
# Must be called before zdot_build_execution_plan
zdot_defer_order() {
    local _ctx_spec=""
    if [[ "${1:-}" == "--context" ]]; then
        if [[ -z "${2:-}" ]]; then
            zdot_error "zdot_defer_order: --context requires a value"
            return 1
        fi
        _ctx_spec="$2"
        shift 2
    fi
    local -a names=("$@")
    if [[ ${#names[@]} -lt 2 ]]; then
        zdot_error "zdot_defer_order: requires at least 2 hook names"
        return 1
    fi
    local i j
    for (( i=1; i<${#names[@]}; i++ )); do
        for (( j=i+1; j<=${#names[@]}; j++ )); do
            _ZDOT_DEFER_ORDER_DEPENDENCIES+=("$_ctx_spec" "${names[$i]}" "${names[$j]}")
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
        local val="${_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$ctx_key]}"
        if [[ -n $val ]]; then
            return 0
        fi
    done
    return 1
}

# Check whether a context-restricted require is active in the current shell.
# Consults _ZDOT_HOOK_REQUIRES_CONTEXTS["hook_id:phase"]:
#   - absent entry  -> require is unconditional (all contexts) -> return 0
#   - present entry -> require is active only in the listed contexts;
#                      return 0 iff _ZDOT_CURRENT_CONTEXT overlaps them
#
# Must be called after zdot_build_context has set _ZDOT_CURRENT_CONTEXT.
# Used at every site that iterates _ZDOT_HOOK_REQUIRES to ensure context-
# restricted edges (e.g. group barrier member phases) are not acted upon
# in shells where the providing member is absent.
_zdot_require_active_in_ctx() {
    local hook_id=$1 phase=$2
    local _key="${hook_id}:${phase}"
    # Absent = unconditional
    [[ -z "${_ZDOT_HOOK_REQUIRES_CONTEXTS[$_key]+x}" ]] && return 0
    # Present = check overlap with current context tokens
    local _ctx
    for _ctx in ${=_ZDOT_CURRENT_CONTEXT}; do
        [[ " ${_ZDOT_HOOK_REQUIRES_CONTEXTS[$_key]} " == *" $_ctx "* ]] && return 0
    done
    return 1
}

# Build execution plan using topological sort (Kahn's algorithm)
# Usage: zdot_build_execution_plan
# Determines current shell context and builds dependency-ordered execution plan
zdot_build_execution_plan() {
    # Determine current shell context via shared function so that the result
    # is available globally for runtime consumers (deferred dispatch, etc.)
    zdot_build_context
    local -a current_contexts=(${=_ZDOT_CURRENT_CONTEXT})
    
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

        # Count dependencies, skipping requires that are inactive in the
        # current context (context-restricted requires have an entry in
        # _ZDOT_HOOK_REQUIRES_CONTEXTS; absent entry means all contexts).
        for phase in $requires; do
            _zdot_require_active_in_ctx "$hook_id" "$phase" || continue
            # Check if phase is promised or has a provider hook in current contexts
            if ! _zdot_has_provider_in_contexts "$phase" "${current_contexts[@]}"; then
                # Required phase has no provider in current context
                if [[ ${_ZDOT_HOOK_OPTIONAL[$hook_id]} == 1 ]]; then
                    skipped_hooks+=("${_ZDOT_HOOKS[$hook_id]} (missing: $phase)")
                    degree=-1  # Mark as skipped
                    break
                else
                    _zdot_internal_error "zdot_build_execution_plan: Hook '${_ZDOT_HOOKS[$hook_id]}' requires phase '$phase' but no hook provides it in current context"
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
            _zdot_require_active_in_ctx "$_hid" "$_ph" || continue
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
    while [[ $_pi -le $(( ${#_ZDOT_DEFER_ORDER_DEPENDENCIES[@]} - 2 )) ]]; do
        local _ctx_spec="${_ZDOT_DEFER_ORDER_DEPENDENCIES[$_pi]}"
        local _from_name="${_ZDOT_DEFER_ORDER_DEPENDENCIES[$(( _pi + 1 ))]}"
        local _to_name="${_ZDOT_DEFER_ORDER_DEPENDENCIES[$(( _pi + 2 ))]}"
        (( _pi += 3 ))

        # Approach A: if this constraint specifies a context and it doesn't
        # intersect the contexts we're building for, silently skip it — the
        # constraint is simply irrelevant to this execution plan.
        if [[ -n "$_ctx_spec" ]]; then
            local _ctx_match=0
            local _cc
            for _cc in "${current_contexts[@]}"; do
                if [[ "$_ctx_spec" == "$_cc" ]]; then
                    _ctx_match=1
                    break
                fi
            done
            if (( ! _ctx_match )); then
                continue
            fi
        fi

        local _hid_a="${_ZDOT_HOOK_BY_NAME[$_from_name]}"
        local _hid_b="${_ZDOT_HOOK_BY_NAME[$_to_name]}"

        # Approach B: distinguish "unknown name" from "not active in context".
        # Case 1: name not found in _ZDOT_HOOK_BY_NAME at all — genuine error.
        if [[ -z "$_hid_a" ]]; then
            _ZDOT_DEFER_ORDER_WARNINGS+=("zdot_defer_order: '$_from_name'→'$_to_name': unknown hook name '$_from_name'; skipping")
            continue
        fi
        if [[ -z "$_hid_b" ]]; then
            _ZDOT_DEFER_ORDER_WARNINGS+=("zdot_defer_order: '$_from_name'→'$_to_name': unknown hook name '$_to_name'; skipping")
            continue
        fi

        # Case 2: hook exists but isn't active in current context — expected
        # for cross-context hooks; silently skip (no warning).
        if [[ -z "${in_degree[$_hid_a]+x}" || -z "${in_degree[$_hid_b]+x}" ]]; then
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
        _zdot_internal_warn "$_w"
    done

    # Seed zero_in_degree from final in_degree values.
    # This pass is intentionally placed AFTER both injection blocks
    # (requires-group and defer-order) so that any in_degree increments
    # performed by those blocks are already reflected before we decide
    # which hooks are immediately schedulable.
    for _zid in ${(k)in_degree}; do
        if [[ ${in_degree[$_zid]} -eq 0 ]]; then
            zero_in_degree+=($_zid)
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

        # Drain synthetic group-member bridge phase.
        #
        # _zdot_init_resolve_groups (plugins.zsh) synthesises barrier hooks
        # that provide `_group_begin_G` and `_group_end_G` phases and injects
        # `_group_member_G_<hid_m>` into each member's _ZDOT_HOOK_PROVIDES.
        # Because those phases are in _ZDOT_HOOK_PROVIDES they are processed
        # by the real-phase loop above — no extra drain is needed here.
        #
        # This comment is kept to explain the absence of such a drain block;
        # see _zdot_init_resolve_groups for the full group-ordering design.
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
    #                unless zdot_allow_defer was called for that
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
    # provided only at deferred-execution time), the hook itself must be
    # deferred.
    #
    # Group requirements (--requires-group G) are handled implicitly:
    # _zdot_init_resolve_groups injects `_group_end_G` into each requiring
    # hook's _ZDOT_HOOK_REQUIRES, so the phase check below naturally covers
    # group membership without any direct _ZDOT_GROUP_MEMBERS lookup here.
    #
    # When a hook is force-deferred:
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
    #                unless zdot_allow_defer pre-acknowledged it
    local changed=1
    while [[ $changed -eq 1 ]]; do
        changed=0
        for hook_id in $_ZDOT_EXECUTION_PLAN; do
            # Already deferred — skip
            [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -gt 0 ]] && continue
            # Check if any required phase is provided only by a deferred hook
            local _force_deferred=0
            local _force_reason=""
            local _force_phase=""
            for phase in ${=_ZDOT_HOOK_REQUIRES[$hook_id]}; do
                _zdot_require_active_in_ctx "$hook_id" "$phase" || continue
                if [[ ${phase_provider_reason[$phase]+x} ]]; then
                    _force_deferred=1
                    _force_reason="${phase_provider_reason[$phase]}"
                    _force_phase="$phase"
                    break
                fi
            done

            if [[ $_force_deferred -eq 1 ]]; then
                # Force-defer this hook
                _ZDOT_EXECUTION_PLAN_DEFERRED+=($hook_id)
                # Propagate: phases this hook provides are now "forced" (transitively)
                for provided in ${=_ZDOT_HOOK_PROVIDES[$hook_id]}; do
                    phase_provider_reason[$provided]="forced"
                done
                # Only warn if the triggering phase came from a force-deferred hook
                # (not an explicit --deferred tool dependency — that is expected/silent)
                if [[ $_force_reason == "forced" ]]; then
                    local func_name="${_ZDOT_HOOKS[$hook_id]}"
                    # Check if the user has accepted this force-deferral
                    local _accepted=0
                    if [[ ${_ZDOT_ACCEPTED_DEFERRED[$func_name]+x} ]]; then
                        local _acceptance="${_ZDOT_ACCEPTED_DEFERRED[$func_name]}"
                        if [[ $_acceptance == "all" ]] || [[ " $_acceptance " == *" $_force_phase "* ]]; then
                            _accepted=1
                        fi
                    fi
                    if [[ $_accepted -eq 0 ]]; then
                        local msg="zdot: WARNING: Hook '$func_name' requires deferred phase '$_force_phase'; it has been force-deferred"
                        _zdot_internal_warn "$msg"
                        if [[ ${_ZDOT_DEFERRED_HOOKS[(Ie)$hook_id]} -eq 0 ]]; then
                            _ZDOT_FORCED_DEFERRED_WARNINGS+=("$msg")
                        fi
                    fi
                fi
                changed=1
            fi
        done
    done

    # Rebuild _ZDOT_EXECUTION_PLAN_DEFERRED in unified topological order.
    #
    # The initial partition (above) added natively-deferred hooks first,
    # then the force-deferral loop appended force-deferred hooks at the
    # end.  This broke the relative ordering that Kahn's algorithm
    # established (e.g. a defer-order edge A→B would be ignored if A was
    # force-deferred and B was natively deferred).
    #
    # Fix: rebuild the deferred list by scanning _ZDOT_EXECUTION_PLAN
    # (which has the correct topological order) and collecting every
    # hook_id that ended up in the deferred set.  We use a temporary
    # associative array for O(1) membership checks.
    local -A _deferred_set
    for hook_id in $_ZDOT_EXECUTION_PLAN_DEFERRED; do
        _deferred_set[$hook_id]=1
    done
    _ZDOT_EXECUTION_PLAN_DEFERRED=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        if [[ ${_deferred_set[$hook_id]+x} ]]; then
            _ZDOT_EXECUTION_PLAN_DEFERRED+=($hook_id)
        fi
    done

    # Report skipped optional hooks if any
    if [[ ${#skipped_hooks} -gt 0 ]]; then
        for skip_msg in $skipped_hooks; do
            zdot_verbose "zdot: Skipping optional hook: $skip_msg"
        done
    fi
    
    return 0
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

            # Synthesise per-member phase and register it.
            # Use local _phase_member=... (with =) so re-declaration on
            # subsequent loop iterations is a safe reinitialisation, not
            # a bare reset that would print the previous value to stdout.
            local _phase_member="_group_member_${_grp}_${_member}"
            if [[ " ${_ZDOT_HOOK_PROVIDES[$_member]:-} " != *" ${_phase_member} "* ]]; then
                _ZDOT_HOOK_PROVIDES[$_member]+="${_ZDOT_HOOK_PROVIDES[$_member]:+ }${_phase_member}"
            fi
            # Register the phase provider only for contexts where the member
            # hook itself participates.  The original code used _ctx_union here
            # which caused a false-cycle: when a member had a narrower context
            # (e.g. interactive-only tmux) than other members (noninteractive
            # node loaders), the group_end barrier appeared in the noninteractive
            # plan but its tmux member phase had no provider there.
            # _reg_ctx is named distinctly from the outer _ctx (used for
            # union building) to make clear these are separate iteration vars.
            for _reg_ctx in ${=_ZDOT_HOOK_CONTEXTS[$_member]:-}; do
                _ZDOT_PHASE_PROVIDERS_BY_CONTEXT[${_reg_ctx}:${_phase_member}]=$_member
            done
            # _reg_ctx is a new name not used elsewhere in this function so
            # declare it with = form inside the loop to keep it local cleanly.
            # (The for loop above handles the actual iteration variable.)

            # End barrier must run after this member's phase.
            # Injected unconditionally into _ZDOT_HOOK_REQUIRES so the global
            # hook graph is complete for all contexts (resolve runs once, plans
            # are built per context).  The context restriction is recorded in
            # _ZDOT_HOOK_REQUIRES_CONTEXTS so every site that iterates requires
            # can call _zdot_require_active_in_ctx to skip this edge in shells
            # where the member is absent.  This keeps the barrier in-plan with
            # only the present members contributing to its in-degree.
            if [[ " ${_ZDOT_HOOK_REQUIRES[$_hid_end]:-} " != *" ${_phase_member} "* ]]; then
                _ZDOT_HOOK_REQUIRES[$_hid_end]+="${_ZDOT_HOOK_REQUIRES[$_hid_end]:+ }${_phase_member}"
                _ZDOT_HOOK_REQUIRES_CONTEXTS[${_hid_end}:${_phase_member}]="${_ZDOT_HOOK_CONTEXTS[$_member]}"
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
            _zdot_internal_warn "zdot_verify_tools: tool '$tool' not found on PATH"
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
        _zdot_internal_debug "zdot: hooks: run: ${func} (hook_id=${hook_id} provides=(${provides[*]}))"
        _ZDOT_CURRENT_HOOK_FUNC=$func
        $func
        local _rc=$?
        _ZDOT_CURRENT_HOOK_FUNC=
        _zdot_internal_debug "zdot: hooks: done: ${func} rc=${_rc}"

        _ZDOT_HOOKS_EXEC_RESULT[$hook_id]=$_rc

        if (( _rc == 0 )); then
            # Mark each provided phase as provided
            for phase in $provides; do
                _ZDOT_PHASES_PROVIDED[$phase]=1
                _zdot_internal_debug "zdot: hooks: provided: ${phase} (by ${func})"
                # Call stop callback if provided
                if [[ -n $stop_callback ]] && $stop_callback "$phase"; then
                    return 2
                fi
            done
            return 0
        else
            _zdot_internal_error "${function_name}: Hook '$func' failed (exit code: $_rc)"
            return 1
        fi
    else
        _ZDOT_HOOKS_EXEC_RESULT[$hook_id]='missing'
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

# Return 0 if every phase required by hook_id — that is active in the
# current shell context — is present in `_ZDOT_PHASES_PROVIDED`, 1 otherwise.
# Context-restricted requires (recorded in _ZDOT_HOOK_REQUIRES_CONTEXTS) are
# skipped when they do not apply to this shell, so a hook is not stalled by
# member phases that were never going to be provided in this context.
_zdot_hook_requirements_met() {
    local hook_id=$1
    local requires=(${=_ZDOT_HOOK_REQUIRES[$hook_id]})
    local req
    for req in $requires; do
        _zdot_require_active_in_ctx "$hook_id" "$req" || continue
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
#   • it is already in `_ZDOT_HOOKS_EXEC_RESULT` (already ran), or
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
        if [[ ${+_ZDOT_HOOKS_EXEC_RESULT[$hook_id]} -eq 1 ]]; then
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
        _zdot_internal_error "_zdot_run_deferred_phase_check: deferred hooks are stalled" \
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
                _zdot_require_active_in_ctx "$hook_id" "$req" || continue
                if [[ ${+_ZDOT_PHASES_PROVIDED[$req]} -eq 0 ]]; then
                    missing_phases+=("$req")
                fi
            done
            _zdot_internal_error "  hook '${hook_label}': waiting for phase(s): ${missing_phases[*]}"
        done
    fi

    # Secondary stall detection: hooks whose requirements ARE met but which are
    # neither queued nor executed — these would be silently stuck (e.g. if a
    # bug incorrectly marks a hook as executed before it runs, or the hook
    # falls through the loop without being dispatched for an unknown reason).
    local -a ready_but_stuck=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -eq 0 ]] && continue
        [[ ${+_ZDOT_HOOKS_EXEC_RESULT[$hook_id]} -eq 1 ]] && continue
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
        # Hooks that declared --group finally are collected in
        # _ZDOT_GROUP_MEMBERS[finally]; execute any that haven't run yet.
        if [[ -n "${_ZDOT_GROUP_MEMBERS[finally]}" ]]; then
            local _finally_hook_id
            for _finally_hook_id in ${=_ZDOT_GROUP_MEMBERS[finally]}; do
                if [[ -z ${_ZDOT_HOOKS_EXEC_RESULT[$_finally_hook_id]} ]]; then
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
# existence checks, phase marking, and `_ZDOT_HOOKS_EXEC_RESULT` bookkeeping.
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
        if [[ -n ${_ZDOT_HOOKS_EXEC_RESULT[$hook_id]} ]]; then
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
        _zdot_internal_error "zdot_execute_all: Completed with $failed failed hook(s)"
        return 1
    fi

    # Detect eager hooks that were in the plan but never ran.
    local -a unexecuted_eager=()
    for hook_id in $_ZDOT_EXECUTION_PLAN; do
        if [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hook_id]} -gt 0 ]]; then
            continue
        fi
        if [[ -z ${_ZDOT_HOOKS_EXEC_RESULT[$hook_id]} ]]; then
            unexecuted_eager+=("${_ZDOT_HOOKS[$hook_id]}")
        fi
    done
    if [[ ${#unexecuted_eager[@]} -gt 0 ]]; then
        _zdot_internal_error "zdot_execute_all: The following eager hooks were in the plan but never ran (possible dependency cycle or missing provider):"
        for _ue in "${unexecuted_eager[@]}"; do
            _zdot_internal_error "  - $_ue"
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
# Introspection and Debugging
# ============================================================================

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
    if [[ ${#_ZDOT_DEFER_ORDER_DEPENDENCIES[@]} -gt 0 ]]; then
        zdot_report "Defer Order Constraints:"
        zdot_info ""
        local _pi=1
        while [[ $_pi -le $(( ${#_ZDOT_DEFER_ORDER_DEPENDENCIES[@]} - 2 )) ]]; do
            local _ctx="${_ZDOT_DEFER_ORDER_DEPENDENCIES[$_pi]}"
            local _fn="${_ZDOT_DEFER_ORDER_DEPENDENCIES[$(( _pi + 1 ))]}"
            local _tn="${_ZDOT_DEFER_ORDER_DEPENDENCIES[$(( _pi + 2 ))]}"
            (( _pi += 3 ))
            local _ctx_label=""
            [[ -n "$_ctx" ]] && _ctx_label=" %F{yellow}[ctx: ${_ctx}]%f"
            zdot_info "  %F{cyan}${_fn}%f → %F{cyan}${_tn}%f${_ctx_label}"
        done
        zdot_info ""
    fi
}

# Set _name_mark, _deferred_mark, _noquiet_mark, _status_mark for a given hook_id/func pair.
# Usage: _zdot_hook_display_marks <hook_id> <func>
# Sets: _name_mark, _deferred_mark, _noquiet_mark, _status_mark (in caller's scope, no local)
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
    _status_mark=""
    if [[ -n "${_ZDOT_HOOKS_EXEC_RESULT[$1]:-}" ]]; then
        local _frc="${_ZDOT_HOOKS_EXEC_RESULT[$1]}"
        if [[ "$_frc" == 'missing' ]]; then
            _status_mark=" %F{red}[not found]%f"
        elif [[ "$_frc" == '0' ]]; then
            _status_mark=" %F{green}[ok]%f"
        else
            _status_mark=" %F{red}[failed: rc=${_frc}]%f"
        fi
    elif (( ${_ZDOT_EXECUTION_PLAN[(Ie)$1]} )); then
        # In plan but never attempted — blocked by unmet dependency
        _status_mark=" %F{yellow}[not run]%f"
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

