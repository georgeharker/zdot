#!/usr/bin/env zsh
# Harness: --requires-optional — a soft dependency that behaves like --requires
# when a provider exists (real ordering edge + force-defer propagation), but is
# silently dropped (hook still runs, build does not abort) when no provider is
# present. Includes the deferred-half: a deferred requirer must not stall at
# runtime on an absent present-phase.
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh hook globals).
# Run:  zsh -f tests/test_requires_if_present.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }

    _t_prov() { : }; _t_cons() { : }

    hid_of() { local fn=$1 hid; for hid in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$hid]} == "$fn" ]] && { print -r -- "$hid"; return 0 }; done; return 1 }
    in_plan() { hid_of "$1" >/dev/null }
    idx_in_plan() { local fn=$1 i=1 hid; for hid in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$hid]} == "$fn" ]] && { print -r -- $i; return 0 }; (( i++ )); done; return 1 }
    is_deferred() { local hid=$(hid_of "$1"); (( ${_ZDOT_EXECUTION_PLAN_DEFERRED[(Ie)$hid]} )) }
    build() { _zdot_init_resolve_groups; zdot_build_execution_plan; }

    case "$2" in
        present-deferred)
            # provider is deferred + consumer --requires-optional it:
            # consumer must build, order AFTER provider, and be force-deferred.
            zdot_register_hook _t_prov interactive noninteractive --deferred --provides p_phase
            zdot_register_hook _t_cons interactive noninteractive --requires-optional p_phase --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            in_plan _t_cons || { print "RESULT: FAIL (consumer missing)"; exit 1 }
            (( $(idx_in_plan _t_prov) < $(idx_in_plan _t_cons) )) || { print "RESULT: FAIL (consumer not ordered after provider)"; exit 1 }
            is_deferred _t_cons || { print "RESULT: FAIL (consumer not force-deferred by present deferred phase)"; exit 1 }
            [[ -z ${_ZDOT_DROPPED_OPTIONAL_PHASES[p_phase]} ]] || { print "RESULT: FAIL (present phase wrongly dropped)"; exit 1 }
            print "RESULT: PASS" ;;

        present-eager)
            # provider eager + consumer --requires-optional it: full edge, ordered
            # after; consumer NOT force-deferred (provider isn't deferred).
            zdot_register_hook _t_prov interactive noninteractive --provides p_phase
            zdot_register_hook _t_cons interactive noninteractive --requires-optional p_phase --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            (( $(idx_in_plan _t_prov) < $(idx_in_plan _t_cons) )) || { print "RESULT: FAIL (not ordered after provider)"; exit 1 }
            is_deferred _t_cons && { print "RESULT: FAIL (consumer wrongly force-deferred)"; exit 1 }
            print "RESULT: PASS" ;;

        absent)
            # no provider for the present-phase: build must NOT abort, consumer
            # still runs, and the phase is recorded as dropped.
            zdot_register_hook _t_cons interactive noninteractive --requires-optional never_provided --provides c_phase
            build || { print "RESULT: FAIL (build aborted on absent present-phase)"; exit 1 }
            in_plan _t_cons || { print "RESULT: FAIL (consumer missing)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_OPTIONAL_PHASES[never_provided]} ]] || { print "RESULT: FAIL (absent phase not recorded as dropped)"; exit 1 }
            print "RESULT: PASS" ;;

        absent-deferred-no-stall)
            # deferred consumer whose only present-phase is absent must report
            # requirements MET at runtime (the dropped phase is ignored), so the
            # deferred drain never stalls on a phase that will never be provided.
            zdot_register_hook _t_cons interactive noninteractive --deferred --requires-optional never_provided --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            local hid=$(hid_of _t_cons)
            # nothing has been provided at runtime yet; the only require is the
            # dropped present-phase, so requirements must already be met.
            if _zdot_hook_requirements_met "$hid"; then
                print "RESULT: PASS"
            else
                print "RESULT: FAIL (deferred consumer stalls on dropped present-phase)"; exit 1
            fi ;;

        mixed)
            # hard --requires alongside --requires-optional: hard one present,
            # soft one absent -> build succeeds, ordered after the hard provider.
            zdot_register_hook _t_prov interactive noninteractive --provides hard_phase
            zdot_register_hook _t_cons interactive noninteractive \
                --requires hard_phase --requires-optional soft_absent --provides c_phase
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            (( $(idx_in_plan _t_prov) < $(idx_in_plan _t_cons) )) || { print "RESULT: FAIL (not ordered after hard provider)"; exit 1 }
            [[ -n ${_ZDOT_DROPPED_OPTIONAL_PHASES[soft_absent]} ]] || { print "RESULT: FAIL (soft phase not dropped)"; exit 1 }
            print "RESULT: PASS" ;;

        hard-still-barfs)
            # regression: a plain --requires on a missing phase must STILL abort.
            zdot_register_hook _t_cons interactive noninteractive --requires genuinely_missing --provides c_phase
            if build 2>/dev/null; then
                print "RESULT: FAIL (hard --requires no longer aborts on missing provider)"; exit 1
            fi
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(present-deferred present-eager absent absent-deferred-no-stall mixed hard-still-barfs)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-26s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0
