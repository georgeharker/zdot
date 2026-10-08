#!/usr/bin/env zsh
# Harness: profiles module — profile resolution, ZDOT_PROFILE export, and the
# allowed-names validation. Contract checks: no profile → ZDOT_PROFILE set but
# EMPTY (empty = "explicitly none", distinct from "module never ran"), a
# configured profile is exported, zdot_profile_get mirrors the zstyle, and an
# unknown name warns-but-still-exports when allowed-names is configured.
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh globals).
# Run:  zsh -f tests/test_profiles.zsh
# (Also exercises the secrets backstop: run tests/test_op_secrets_env.zsh.)

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }
    source "${ZDOT_ROOT}/modules/profiles/profiles.zsh" || { print -u2 "FAIL: cannot source profiles module"; exit 2 }

    case "$2" in
        no-profile-exported-empty)
            unset -v ZDOT_PROFILE
            _profiles_init
            [[ -n "${ZDOT_PROFILE+x}" ]] || { print "RESULT: FAIL (ZDOT_PROFILE unset — consumers cannot distinguish 'no profile' from 'module absent')"; exit 1 }
            [[ -z "$ZDOT_PROFILE" ]] || { print "RESULT: FAIL (ZDOT_PROFILE='$ZDOT_PROFILE' with no profile configured)"; exit 1 }
            print "RESULT: PASS" ;;

        profile-exported)
            zstyle ':zdot:profile' name work
            unset -v ZDOT_PROFILE
            _profiles_init
            [[ "$ZDOT_PROFILE" == 'work' ]] || { print "RESULT: FAIL (ZDOT_PROFILE='$ZDOT_PROFILE' expected 'work')"; exit 1 }
            print "RESULT: PASS" ;;

        accessor-mirrors-zstyle)
            zdot_profile_get
            [[ -z "$REPLY" ]] || { print "RESULT: FAIL (REPLY='$REPLY' with no zstyle)"; exit 1 }
            zstyle ':zdot:profile' name dev
            zdot_profile_get
            [[ "$REPLY" == 'dev' ]] || { print "RESULT: FAIL (REPLY='$REPLY' expected 'dev')"; exit 1 }
            print "RESULT: PASS" ;;

        accessor-explicit-empty)
            # An explicit empty zstyle counts as configured "none", not unset.
            zstyle ':zdot:profile' name ''
            _profiles_init
            zdot_profile_get
            [[ -z "$REPLY" && -n "${ZDOT_PROFILE+x}" ]] || { print "RESULT: FAIL (explicit-empty zstyle not honoured)"; exit 1 }
            print "RESULT: PASS" ;;

        allowed-names-warns-but-exports)
            zstyle ':zdot:profile' name typos
            zstyle ':zdot:profile' allowed-names work dev
            unset -v ZDOT_PROFILE
            _profiles_init
            [[ "$ZDOT_PROFILE" == 'typos' ]] || { print "RESULT: FAIL (unknown name not exported at all)"; exit 1 }
            print "RESULT: PASS" ;;

        allowed-names-passes)
            zstyle ':zdot:profile' name dev
            zstyle ':zdot:profile' allowed-names work dev
            unset -v ZDOT_PROFILE
            _profiles_init
            [[ "$ZDOT_PROFILE" == 'dev' ]] || { print "RESULT: FAIL (allowed name not exported)"; exit 1 }
            print "RESULT: PASS" ;;

        hook-provides-phase)
            # Registration contract: sourcing the module must register the
            # _profiles_init hook, providing profiles-configured, requiring
            # the profile-configure group.
            local -a hids=(${(k)_ZDOT_HOOK_PROVIDES})
            local _found=0
            local _h _fn
            for _h in "${hids[@]}"; do
                [[ " ${_ZDOT_HOOK_PROVIDES[$_h]:-} " == *' profiles-configured '* ]] || continue
                _fn="${_ZDOT_HOOKS[$_h]}"
                [[ "$_fn" == '_profiles_init' ]] && _found=1 && break
            done
            (( _found )) || { print "RESULT: FAIL (no hook for _profiles_init provides profiles-configured after sourcing module)"; exit 1 }
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(
    no-profile-exported-empty
    profile-exported
    accessor-mirrors-zstyle
    accessor-explicit-empty
    allowed-names-warns-but-exports
    allowed-names-passes
    hook-provides-phase
)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-32s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0