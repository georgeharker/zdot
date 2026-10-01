#!/usr/bin/env zsh
# Harness: --requires-optional-tool — optional-tool dependency (config-driven manifest).
#
# Plan-build semantics are exactly --requires-optional's on the tool: phase
# (soft when no provider module, full dependency when one is). On TOP of that,
# the hook is skipped at execution (body-entry gate) when the tool is not on
# PATH — a check only reliable there, because a provider's own hook may be
# what puts the tool on PATH. A runtime-skipped hook marks no provides; its
# phases enter _ZDOT_DROPPED_EXECUTION_PHASES, so consumers drop
# (requires-optional) or cascade-skip (hard) instead of running on absent
# state — and deferred consumers never stall on those phases.
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh hook globals).
# Run:  zsh -f tests/test_requires_optional_tool.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }

    # Tools used by this harness:
    _T_PRESENT="zsh"                       # always installable: the zsh binary itself
    _T_ABSENT="zdot-test-tool-definitely-absent"  # never on PATH in the harness

    _t_p() { : }; _t_c() { : }; _t_s() { : }; _t_d() { : }  # shuck: ignore=C063  # invoked dynamically via _ZDOT_HOOKS lookup, not by direct call

    hid_of() { local fn=$1 hid; for hid in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$hid]} == "$fn" ]] && { print -r -- "$hid"; return 0 }; done; return 1 }
    idx_in_plan() { local fn=$1 i=1 hid; for hid in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$hid]} == "$fn" ]] && { print -r -- $i; return 0 }; (( i++ )); done; return 1 }
    build() { _zdot_init_resolve_groups; zdot_build_execution_plan; }
    # Replicate zdot_execute_all's eager loop without the deferred-drain
    # machinery (gates live in _zdot_execute_hook, so this exercises them).
    run_eager() { local hid; for hid in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hid]} -gt 0 ]] && continue; _zdot_execute_hook "$hid" "test"; done }

    case "$2" in
        provider-present-tool-absent)
            # Manifest provider claims tool:<T> but the tool isn't installed.
            # The consumer must: build, order after the provider, then be
            # runtime-skipped at body entry; provides NOT marked; phases
            # recorded as runtime-dropped.
            zdot_register_hook _t_p interactive noninteractive --provides tool:$_T_ABSENT p_ready
            zdot_register_hook _t_c interactive noninteractive \
                --requires-optional-tool $_T_ABSENT --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            (( $(idx_in_plan _t_p) < $(idx_in_plan _t_c) )) || { print "RESULT: FAIL (not ordered after provider)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]} == 'skipped-tool' ]] || { print "RESULT: FAIL (consumer not tool-gated; result=${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]})"; exit 1 }
            [[ ${+_ZDOT_PHASES_PROVIDED[c_phase]} -eq 0 ]] || { print "RESULT: FAIL (skipped hook still marked provides)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_EXECUTION_PHASES[c_phase]} ]] || { print "RESULT: FAIL (phase not execution-dropped)"; exit 1 }
            print "RESULT: PASS" ;;

        provider-present-tool-present)
            # Tool installed (zsh is always here): the gate passes, both hooks
            # run, the consumer's provides are marked.
            zdot_register_hook _t_p interactive noninteractive --provides tool:$_T_PRESENT p_ready
            zdot_register_hook _t_c interactive noninteractive \
                --requires-optional-tool $_T_PRESENT --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]} -eq 0 ]] || { print "RESULT: FAIL (consumer not executed)"; exit 1 }
            [[ ${+_ZDOT_PHASES_PROVIDED[c_phase]} -eq 1 ]] || { print "RESULT: FAIL (provides not marked)"; exit 1 }
            print "RESULT: PASS" ;;

        no-provider-tool-present)
            # Hand-installed tool, no manifest module: edge dropped at
            # plan-build (same as --requires-optional), hook runs anyway.
            zdot_register_hook _t_c interactive noninteractive \
                --requires-optional-tool $_T_PRESENT --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_OPTIONAL_PHASES[tool:$_T_PRESENT]} ]] || { print "RESULT: FAIL (unprovided soft tool-phase not dropped at plan-build)"; exit 1 }
            run_eager
            [[ ${+_ZDOT_PHASES_PROVIDED[c_phase]} -eq 1 ]] || { print "RESULT: FAIL (hook did not run despite installed tool)"; exit 1 }
            print "RESULT: PASS" ;;

        no-provider-tool-absent)
            # Neither provider nor tool: edge dropped, hook runtime-skipped.
            zdot_register_hook _t_c interactive noninteractive \
                --requires-optional-tool $_T_ABSENT --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]} == 'skipped-tool' ]] || { print "RESULT: FAIL (hook not skipped)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_EXECUTION_PHASES[c_phase]} ]] || { print "RESULT: FAIL (phase not execution-dropped)"; exit 1 }
            print "RESULT: PASS" ;;

        cascade-eager)
            # Full runtime cascade: P tool-skipped -> p_phase dropped ->
            # C (hard require) cascade-skipped -> c_phase dropped ->
            # D (hard require) cascade-skipped.
            zdot_register_hook _t_p interactive noninteractive --requires-optional-tool $_T_ABSENT --provides p_phase
            zdot_register_hook _t_c interactive noninteractive --requires p_phase --provides c_phase
            zdot_register_hook _t_d interactive noninteractive --requires c_phase --provides d_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_p)]} == 'skipped-tool' ]] || { print "RESULT: FAIL (P not tool-skipped)"; exit 1 }
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]} == 'skipped-cascade' ]] || { print "RESULT: FAIL (C not cascade-skipped; result=${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]})"; exit 1 }
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_d)]} == 'skipped-cascade' ]] || { print "RESULT: FAIL (D not cascade-skipped)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_EXECUTION_PHASES[p_phase]} && -n ${_ZDOT_DROPPED_EXECUTION_PHASES[c_phase]} && -n ${_ZDOT_DROPPED_EXECUTION_PHASES[d_phase]} ]] || { print "RESULT: FAIL (phases not all execution-dropped)"; exit 1 }
            print "RESULT: PASS" ;;

        cascade-soft-consumer-runs)
            # A --requires-optional consumer of a runtime-dropped phase still
            # runs (edge dropped), mirroring plan-build softness.
            zdot_register_hook _t_p interactive noninteractive --requires-optional-tool $_T_ABSENT --provides p_phase
            zdot_register_hook _t_s interactive noninteractive --requires-optional p_phase --provides s_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_s)]} -eq 0 ]] || { print "RESULT: FAIL (soft consumer did not run)"; exit 1 }
            [[ ${+_ZDOT_PHASES_PROVIDED[s_phase]} -eq 1 ]] || { print "RESULT: FAIL (soft consumer provides not marked)"; exit 1 }
            print "RESULT: PASS" ;;

        deferred-hard-drop-skips)
            # Deferred-half: a deferred HARD consumer of a runtime-dropped
            # phase is cascade-skipped by the dispatch gate...
            zdot_register_hook _t_p interactive noninteractive --requires-optional-tool $_T_ABSENT --provides p_phase
            zdot_register_hook _t_d interactive noninteractive --deferred --requires p_phase --provides d_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            # Simulate the drain's wave for _t_d: the gate must say skip...
            if ! _zdot_runtime_gate_skip "$(hid_of _t_d)"; then
                print "RESULT: FAIL (deferred hard consumer not cascade-skipped)"; exit 1
            fi
            # ...and running it through the gate path records the terminal state.
            _ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_d)]='skipped-cascade'
            _zdot_register_runtime_skip "$(hid_of _t_d)"
            [[ -n ${_ZDOT_DROPPED_EXECUTION_PHASES[d_phase]} ]] || { print "RESULT: FAIL (deferred skip did not drop its provides)"; exit 1 }
            print "RESULT: PASS" ;;

        deferred-soft-drop-runs)
            # ...while a deferred REQUIRES-OPTIONAL consumer is dropped (gate
            # says run; requirements met) and must never stall.
            zdot_register_hook _t_p interactive noninteractive --requires-optional-tool $_T_ABSENT --provides p_phase
            zdot_register_hook _t_d interactive noninteractive --deferred --requires-optional p_phase --provides d_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            if _zdot_runtime_gate_skip "$(hid_of _t_d)"; then
                print "RESULT: FAIL (soft consumer wrongly cascade-skipped)"; exit 1
            fi
            if _zdot_hook_requirements_met "$(hid_of _t_d)"; then
                print "RESULT: PASS"
            else
                print "RESULT: FAIL (deferred soft consumer stalls on runtime-dropped phase)"; exit 1
            fi ;;

        longhand-sugar-equivalent)
            # The gate list is DERIVED from the requires-optional set, so the
            # longhand --requires-optional tool:<t> must gate exactly like the
            # sugar.
            zdot_register_hook _t_c interactive noninteractive \
                --requires-optional "tool:$_T_ABSENT" --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]} == 'skipped-tool' ]] || { print "RESULT: FAIL (longhand form not tool-gated)"; exit 1 }
            print "RESULT: PASS" ;;

        hard-tool-no-gate)
            # Regression: plain --requires-tool keeps pure claim semantics —
            # manifested-but-uninstalled does NOT gate the hook (opt-in only).
            zdot_register_hook _t_p interactive noninteractive --provides tool:$_T_ABSENT p_ready
            zdot_register_hook _t_c interactive noninteractive \
                --requires-tool $_T_ABSENT --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_c)]} -eq 0 ]] || { print "RESULT: FAIL (hard tool require unexpectedly gated)"; exit 1 }
            print "RESULT: PASS" ;;

        verify-unconfigured-errors)
            # CONFIG CONTRACT: an unset verify-tools manifest is an error (rc 1,
            # error message emitted/deferred) — not a silent default.
            local _failed
            { zdot_verify_tools_zstyle ':zdot:test-verify-nosuch' 2>/dev/null } && _failed=0 || _failed=1
            [[ $_failed -eq 1 ]] || { print "RESULT: FAIL (unconfigured manifest did not error)"; exit 1 }
            print "RESULT: PASS" ;;

        verify-blank-ok)
            # Set-but-blank is legitimate: an intentionally empty manifest
            # verifies trivially (rc 0, nothing emitted).
            zstyle ':zdot:test-verify-blank' verify-tools ''
            typeset _rc
            { zdot_verify_tools_zstyle ':zdot:test-verify-blank' 2>/dev/null } && _rc=0 || _rc=1
            [[ $_rc -eq 0 ]] || { print "RESULT: FAIL (blank manifest not accepted)"; exit 1 }
            [[ ${#_ZDOT_DEFERRED_MESSAGES} -eq 0 ]] || { print "RESULT: FAIL (blank manifest emitted output)"; exit 1 }
            print "RESULT: PASS" ;;

        verify-optional-quiet)
            # Verify demotion: a missing tool in the optional-tools list is
            # verified quietly (no zdot_verify_tools warning line); a missing
            # tool outside it still warns. NOTE: in a non-interactive test
            # shell _zdot_internal_warn defers into _ZDOT_DEFERRED_MESSAGES
            # instead of stderr — so the call must run in THIS shell (not
            # inside $(...): a command substitution's subshell doesn't
            # propagate the array). The warn format is tool '<name>' (quoted);
            # the demoted miss appears only in an unquoted debug line.
            _ZDOT_DEFERRED_MESSAGES=()
            zstyle ':zdot:test-verify' verify-tools hard-test-tool-absent opt-test-tool-absent
            zstyle ':zdot:test-verify' optional-tools opt-test-tool-absent
            typeset _all
            zdot_verify_tools_zstyle ':zdot:test-verify' 2>/dev/null
            _all="${_ZDOT_DEFERRED_MESSAGES}"
            [[ "$_all" == *"tool 'hard-test-tool-absent'"* ]] \
                || { print "RESULT: FAIL (hard missing tool not warned)"; exit 1 }
            [[ "$_all" != *"tool 'opt-test-tool-absent'"* ]] \
                || { print "RESULT: FAIL (optional missing tool wrongly warned)"; exit 1 }
            print "RESULT: PASS" ;;

        provider-failure-terminal)
            # A provider that FAILS (rc≠0) is terminal for its consumers too,
            # same gates as tool-skips: soft deferred consumer drops the edge
            # (requirements met — the drain must NOT stall on it); hard
            # deferred consumer is cascade-skipped by the gate.
            _t_fail() { return 7 }  # shuck: ignore=C063  # invoked dynamically via _ZDOT_HOOKS lookup
            zdot_register_hook _t_fail interactive noninteractive --provides f_phase
            zdot_register_hook _t_s interactive noninteractive \
                --deferred --requires-optional f_phase --provides s_phase
            zdot_register_hook _t_d interactive noninteractive \
                --deferred --requires f_phase --provides d_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            run_eager
            [[ ${_ZDOT_HOOKS_EXEC_RESULT[$(hid_of _t_fail)]} == 7 ]] || { print "RESULT: FAIL (provider rc not recorded)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_EXECUTION_PHASES[f_phase]} ]] || { print "RESULT: FAIL (failed provider's phase not execution-dropped)"; exit 1 }
            if ! _zdot_hook_requirements_met "$(hid_of _t_s)"; then
                print "RESULT: FAIL (soft consumer stalls on failed provider)"; exit 1
            fi
            if ! _zdot_runtime_gate_skip "$(hid_of _t_d)"; then
                print "RESULT: FAIL (hard consumer not cascade-skipped after provider failure)"; exit 1
            fi
            print "RESULT: PASS" ;;

        tool_predicate)
            # zdot_tool_available: 0 iff every tool found, 1 otherwise.
            if ! zdot_tool_available zsh; then
                print "RESULT: FAIL (zsh should be available)"; exit 1
            fi
            if zdot_tool_available zsh "${_T_ABSENT}"; then
                print "RESULT: FAIL (absent tool reported available)"; exit 1
            fi
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(
    provider-present-tool-absent
    provider-present-tool-present
    no-provider-tool-present
    no-provider-tool-absent
    cascade-eager
    cascade-soft-consumer-runs
    deferred-hard-drop-skips
    deferred-soft-drop-runs
    longhand-sugar-equivalent
    hard-tool-no-gate
    verify-unconfigured-errors
    verify-blank-ok
    provider-failure-terminal
    verify-optional-quiet
    tool_predicate
)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-30s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0