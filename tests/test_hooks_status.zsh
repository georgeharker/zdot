#!/usr/bin/env zsh
# Harness: zdot_hooks_status — sectioning, outcome counting, exit status.
#
# Pins three behaviours that were previously wrong:
#   1. _ZDOT_EXECUTION_PLAN holds eager AND deferred ids; a deferred hook must be
#      listed (and counted) once, under Deferred — not also under Eager.
#   2. Runtime gate skips (skipped-tool / skipped-cascade) are deliberate
#      outcomes, not failures: counted as "skipped", exit status unaffected.
#   3. An un-run deferred hook is "pending" while the drain hasn't finished, and
#      "not run (drain stalled)" — a failure — once it has (previously never
#      counted, so a stalled drain exited 0).
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh globals).
# Run:  zsh -f tests/test_hooks_status.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }

    _t_eager() { : }; _t_def() { : }; _t_skip() { : }; _t_bad() { return 3 }

    # Build a plan, then run only the eager part directly (no ZLE → no drain).
    setup() {
        zdot_register_hook _t_eager interactive noninteractive --provides eager-ready
        zdot_register_hook _t_def   interactive noninteractive --deferred --provides def-ready
        zdot_register_hook _t_skip  interactive noninteractive \
            --requires-optional-tool __zdot_no_such_tool__ --provides skip-ready
        [[ "$1" == with-failure ]] && \
            zdot_register_hook _t_bad interactive noninteractive --provides bad-ready
        _zdot_init_resolve_groups; zdot_build_execution_plan || { print "RESULT: FAIL (build aborted)"; exit 1 }
        local h
        for h in $_ZDOT_EXECUTION_PLAN; do
            (( ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$h]} )) || _zdot_execute_hook "$h" test 2>/dev/null
        done
    }
    # Run zdot_hooks_status; capture plain-text output in $out and rc in $rc.
    run_status() {
        out="$(zdot_hooks_status "$@" 2>&1)"; rc=$?
        out="${out//$'\e'\[[0-9;]#m/}"
    }
    has() { [[ "$1" == *"$2"* ]] }

    case "$2" in
        deferred-listed-once)
            setup
            run_status
            local eager_sec="${${out#*Eager:}%%Deferred:*}"
            has "$eager_sec" "_t_def" && { print "RESULT: FAIL (deferred hook listed under Eager)"; exit 1 }
            has "${out#*Deferred:}" "_t_def" || { print "RESULT: FAIL (deferred hook missing from Deferred)"; exit 1 }
            print "RESULT: PASS" ;;

        skip-is-not-failure)
            setup
            run_status
            has "$out" "[skipped: tool]" || { print "RESULT: FAIL (skip mark missing)"; exit 1 }
            has "$out" "Eager:    2 ok, 1 skipped, 0 failed, 0 not run" \
                || { print "RESULT: FAIL (eager summary wrong): $(print -r -- "$out" | grep 'Eager: ')"; exit 1 }
            (( rc == 0 )) || { print "RESULT: FAIL (rc=$rc with only a gate skip)"; exit 1 }
            print "RESULT: PASS" ;;

        deferred-pending-vs-stalled)
            setup
            run_status
            has "$out" "Deferred: 0 ok, 0 skipped, 0 failed, 1 pending" \
                || { print "RESULT: FAIL (undrained deferred should be pending): $(print -r -- "$out" | grep 'Deferred: ')"; exit 1 }
            (( rc == 0 )) || { print "RESULT: FAIL (rc=$rc while drain pending)"; exit 1 }
            # Simulate a finished drain that never reached _t_def.
            _ZDOT_DEFER_WALL_MS=5.000
            run_status
            has "$out" "1 not run (drain stalled)" || { print "RESULT: FAIL (stalled drain not reported)"; exit 1 }
            (( rc == 1 )) || { print "RESULT: FAIL (rc=$rc for stalled drain)"; exit 1 }
            print "RESULT: PASS" ;;

        failure-sets-rc)
            setup with-failure
            run_status
            has "$out" "[failed: rc=3]" || { print "RESULT: FAIL (failure mark missing)"; exit 1 }
            has "$out" "1 failed" || { print "RESULT: FAIL (failure not counted)"; exit 1 }
            (( rc == 1 )) || { print "RESULT: FAIL (rc=$rc with a failed hook)"; exit 1 }
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(
    deferred-listed-once
    skip-is-not-failure
    deferred-pending-vs-stalled
    failure-sets-rc
)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-28s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0
