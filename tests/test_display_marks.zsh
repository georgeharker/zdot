#!/usr/bin/env zsh
# Harness: display marks — _zdot_hook_display_marks (assoc reply:
# name/deferred/noquiet/status) and _zdot_ran_deferred_mark (REPLY).
#
# These pins the mark VOCABULARY and the assoc consumer idiom, so mark changes
# (glyphs, new statuses like [skipped: tool]/[skipped: cascade]) are decided
# changes, not accidents. Assertions match on bracket CONTENT (tolerant of the
# %F{...}/%f escapes and Nerd-Font glyphs), not byte-exact strings.
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh globals).
# Run:  zsh -f tests/test_display_marks.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }

    _t_foo() { : }; _t_provp() { : }

    # Register with BOTH contexts (an interactive-only registration drops out
    # of the plan in a non-interactive -f test shell). Resolve+build so hooks
    # are "planned".
    register_in_plan() {
        zdot_register_hook "$@" interactive noninteractive
        _zdot_init_resolve_groups; zdot_build_execution_plan || { print "RESULT: FAIL (build aborted)"; exit 1 }
    }
    marks_of() {
        # typeset -gA (NOT plain -A): a plain typeset here would make _mk a
        # helper-local that dies on return, and the case scope would read an
        # empty assoc (the test_op_secrets_env pitfall, second offense).
        typeset -gA _mk
        _zdot_hook_display_marks "$1" "$2" && _mk=("${reply[@]}")
        (( ${#reply} % 2 == 0 )) || { print "RESULT: FAIL (odd pair list)"; exit 1 }
    }
    has() { [[ "$1" == *"$2"* ]] }

    case "$2" in
        not-run-and-nameless)
            register_in_plan _t_foo --provides foo-ready
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            marks_of "$hid" "_t_foo"
            has "${_mk[name]}" "[name" && { print "RESULT: FAIL (name mark set for a --name-less hook)"; exit 1 }
            has "${_mk[deferred]}" "[" && { print "RESULT: FAIL (deferred mark set)"; exit 1 }
            has "${_mk[status]}" "[not run]" || { print "RESULT: FAIL (planned+unexecuted should be [not run]); got <${_mk[status]}>"; exit 1 }
            print "RESULT: PASS" ;;

        name-mark)
            register_in_plan _t_foo --name fancy-name --provides foo-ready
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            marks_of "$hid" "_t_foo"
            has "${_mk[name]}" "[name: fancy-name]" || { print "RESULT: FAIL (name mark missing; got <${_mk[name]}>)"; exit 1 }
            print "RESULT: PASS" ;;

        deferred-flag)
            register_in_plan _t_foo --deferred --provides foo-ready
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            marks_of "$hid" "_t_foo"
            # NOTE: the glyph sits between the brackets ("[ deferred]"), so
            # match the closing part, not the opening bracket.
            has "${_mk[deferred]}" "deferred]" || { print "RESULT: FAIL (--deferred mark missing; got <${_mk[deferred]}>)"; exit 1 }
            has "${_mk[deferred]}" "forced" && { print "RESULT: FAIL (explicit defer wrongly says forced)"; exit 1 }
            print "RESULT: PASS" ;;

        forced-deferred)
            # Provider --deferred; consumer hard-requires it => consumer is
            # force-deferred at plan build => "[deferred: forced]".
            register_in_plan _t_provp --deferred --provides p_phase
            zdot_register_hook _t_foo interactive noninteractive --requires p_phase --provides c_phase
            _zdot_init_resolve_groups; zdot_build_execution_plan
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            [[ -n "$hid" ]] || { print "RESULT: FAIL (consumer missing from plan)"; exit 1 }
            marks_of "$hid" "_t_foo"
            has "${_mk[deferred]}" "deferred: forced]" || { print "RESULT: FAIL (forced mark missing; got <${_mk[deferred]}>)"; exit 1 }
            print "RESULT: PASS" ;;

        status-vocabulary)
            # The full exec-result vocabulary in one sweep. Uses a bare hook
            # (not planned): status keys off _ZDOT_HOOKS_EXEC_RESULT alone.
            zdot_register_hook _t_foo interactive noninteractive --provides foo-ready
            hid=$REPLY
            typeset -A want=(
                0               "[ok]"
                missing         "[not found]"
                7               "[failed: rc=7]"
                skipped-tool    "[skipped: tool]"
                skipped-cascade "[skipped: cascade]"
            )
            for rc in ${(k)want}; do
                _ZDOT_HOOKS_EXEC_RESULT[$hid]=$rc
                marks_of "$hid" "_t_foo"
                has "${_mk[status]}" "${want[$rc]}" \
                    || { print "RESULT: FAIL (rc=$rc: status <${_mk[status]}> lacks ${want[$rc]})"; exit 1 }
            done
            print "RESULT: PASS" ;;

        noquiet-mark)
            register_in_plan _t_foo --deferred-prompt --provides foo-ready
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            marks_of "$hid" "_t_foo"
            has "${_mk[noquiet]}" "[" || { print "RESULT: FAIL (noquiet mark missing; got <${_mk[noquiet]}>)"; exit 1 }
            print "RESULT: PASS" ;;

        ran-deferred)
            # Empty registry: empty word. Simulated defer submission: mark set.
            register_in_plan _t_foo --provides foo-ready
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            _zdot_ran_deferred_mark "$hid"
            [[ -z "$REPLY" ]] || { print "RESULT: FAIL (ran-deferred set with no defers)"; exit 1 }
            _zdot_ran_deferred_mark "$hid"
            _ZDOT_DEFER_HOOKS+=( "_t_foo" )
            _zdot_ran_deferred_mark "$hid"
            has "$REPLY" "[ran deferred]" || { print "RESULT: FAIL (mark missing after defer submission)"; exit 1 }
            print "RESULT: PASS" ;;

        consumer-idiom-composes)
            # The documented consumer idiom end-to-end: assoc capture, direct
            # interpolation, subset composition.
            register_in_plan _t_foo --name fancy-name --provides foo-ready
            hid=$(for h in $_ZDOT_EXECUTION_PLAN; do [[ ${_ZDOT_HOOKS[$h]} == _t_foo ]] && print $h; done)
            _ZDOT_HOOKS_EXEC_RESULT[$hid]=0
            marks_of "$hid" "_t_foo"
            local out="_t_foo${_mk[name]}${_mk[status]}"
            has "$out" "[name: fancy-name]" || { print "RESULT: FAIL (name not composed)"; exit 1 }
            has "$out" "[ok]" || { print "RESULT: FAIL (status not composed)"; exit 1 }
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(
    not-run-and-nameless
    name-mark
    deferred-flag
    forced-deferred
    status-vocabulary
    noquiet-mark
    ran-deferred
    consumer-idiom-composes
)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-24s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0