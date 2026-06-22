#!/usr/bin/env zsh
# Harness: an --optional group member that gets skipped must not poison the
# group's end barrier (and thus a non-optional --requires-group consumer).
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh hook globals).
# Run:  zsh -f tests/test_optional_group_member.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

# ---------------------------------------------------------------------------
# Sub-process entry: run a single named case and print "RESULT: PASS|FAIL ...".
# ---------------------------------------------------------------------------
if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }

    _t_a() { : }; _t_b() { : }; _t_c() { : }

    in_plan() {  # in_plan <fn>
        local fn=$1 hid
        for hid in $_ZDOT_EXECUTION_PLAN; do
            [[ ${_ZDOT_HOOKS[$hid]} == "$fn" ]] && return 0
        done
        return 1
    }
    build() { _zdot_init_resolve_groups; zdot_build_execution_plan; }

    case "$2" in
        skipped-member)
            # present member + skipped optional member + non-optional consumer
            zdot_register_hook _t_a interactive noninteractive --group g --provides a
            zdot_register_hook _t_b interactive noninteractive --group g --optional \
                --requires tool:definitely-not-installed --provides b
            zdot_register_hook _t_c interactive noninteractive --requires-group g --provides c
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            in_plan _t_a || { print "RESULT: FAIL (present member missing)"; exit 1 }
            in_plan _t_c || { print "RESULT: FAIL (consumer missing)"; exit 1 }
            in_plan _t_b && { print "RESULT: FAIL (skipped member should be absent)"; exit 1 }
            print "RESULT: PASS" ;;

        all-skipped)
            # every member optional & skipped -> end barrier vacuous, consumer runs
            zdot_register_hook _t_a interactive noninteractive --group g --optional \
                --requires tool:nope-1 --provides a
            zdot_register_hook _t_b interactive noninteractive --group g --optional \
                --requires tool:nope-2 --provides b
            zdot_register_hook _t_c interactive noninteractive --requires-group g --provides c
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            in_plan _t_c || { print "RESULT: FAIL (consumer missing)"; exit 1 }
            in_plan _t_a && { print "RESULT: FAIL (a should be absent)"; exit 1 }
            in_plan _t_b && { print "RESULT: FAIL (b should be absent)"; exit 1 }
            print "RESULT: PASS" ;;

        nonoptional-missing)
            # a NON-optional hook with a genuinely missing require must STILL
            # hard-error (regression guard: pre-pass only skips --optional hooks)
            zdot_register_hook _t_a interactive noninteractive \
                --requires tool:definitely-not-installed --provides a
            if build 2>/dev/null; then
                print "RESULT: FAIL (expected hard error, build succeeded)"; exit 1
            fi
            print "RESULT: PASS" ;;

        plain-group)
            # baseline: present-only group, no optional members
            zdot_register_hook _t_a interactive noninteractive --group g --provides a
            zdot_register_hook _t_c interactive noninteractive --requires-group g --provides c
            build || { print "RESULT: FAIL (build aborted)"; exit 1 }
            in_plan _t_a || { print "RESULT: FAIL (member missing)"; exit 1 }
            in_plan _t_c || { print "RESULT: FAIL (consumer missing)"; exit 1 }
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

# ---------------------------------------------------------------------------
# Driver: run each case in a fresh subshell, aggregate.
# ---------------------------------------------------------------------------
typeset -a cases=(skipped-member all-skipped nonoptional-missing plain-group)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-22s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0
