#!/usr/bin/env zsh
# Harness: _op_get_secrets_env — the secrets env resolver. Returns a flat
# name/value pair list in $reply (src_dir / cache / suffix). Contract checks:
# even-length pairs, named keys readable via typeset -A, the profile suffix is
# '' (EMPTY WORD) when no profile is configured — NOT '-' (regression for the
# bare-word [[ -n op_secrets_profile ]] bug that made every machine look for
# secrets-.zsh), and '-<profile>' when it is. XDG overrides are honoured.
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh globals).
# Run:  zsh -f tests/test_op_secrets_env.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }
    source "${ZDOT_ROOT}/modules/profiles/profiles.zsh" || { print -u2 "FAIL: cannot source profiles module"; exit 2 }
    source "${ZDOT_ROOT}/modules/secrets/secrets.zsh" || { print -u2 "FAIL: cannot source secrets module"; exit 2 }

    # NOTE: _se must be declared at THIS (case) scope BEFORE assignment —
    # assigning _se=(...) inside a helper function without a prior typeset
    # creates a local that dies on return. No resolve_into helper for exactly
    # that reason.
    typeset -A _se

    case "$2" in
        no-profile-suffix-empty)
            unset -v XDG_CONFIG_HOME XDG_CACHE_HOME
            _op_get_secrets_env && _se=("${reply[@]}")
            (( ${#reply} % 2 == 0 )) || { print "RESULT: FAIL (odd-length pair list: ${#reply} elements)"; exit 1 }
            typeset -A _se
            [[ -z "${_se[suffix]}" ]] || { print "RESULT: FAIL (suffix='${_se[suffix]}' with no profile configured — bare-word [[ -n ]] bug?)"; exit 1 }
            [[ "${_se[src_dir]}" == "$HOME/.config/secrets" ]] || { print "RESULT: FAIL (src_dir=${_se[src_dir]})"; exit 1 }
            [[ "${_se[cache]}" == "$HOME/.cache/secrets" ]] || { print "RESULT: FAIL (cache=${_se[cache]})"; exit 1 }
            print "RESULT: PASS" ;;

        profile-suffix-dash)
            zstyle ':zdot:secrets:op' profile work
            _op_get_secrets_env && _se=("${reply[@]}")
            typeset -A _se
            [[ "${_se[suffix]}" == '-work' ]] || { print "RESULT: FAIL (suffix='${_se[suffix]}' expected '-work')"; exit 1 }
            print "RESULT: PASS" ;;

        xdg-overrides)
            XDG_CONFIG_HOME=/tmp/test-xdg-config
            XDG_CACHE_HOME=/tmp/test-xdg-cache
            _op_get_secrets_env && _se=("${reply[@]}")
            typeset -A _se
            [[ "${_se[src_dir]}" == "/tmp/test-xdg-config/secrets" ]] || { print "RESULT: FAIL (XDG_CONFIG_HOME ignored)"; exit 1 }
            [[ "${_se[cache]}" == "/tmp/test-xdg-cache/secrets" ]] || { print "RESULT: FAIL (XDG_CACHE_HOME ignored)"; exit 1 }
            print "RESULT: PASS" ;;

        consumer-pattern)
            # The documented consumer idiom must actually work end-to-end,
            # including the empty-suffix word dropping out of the local.
            zstyle ':zdot:secrets:op' profile ''
            _op_get_secrets_env && _se2=("${reply[@]}")
            local secrets_src_dir="${_se2[src_dir]}" secrets_cache="${_se2[cache]}" \
                op_secrets_profile_suffix="${_se2[suffix]}"
            [[ -z "$op_secrets_profile_suffix" ]] || { print "RESULT: FAIL (consumer got suffix='$op_secrets_profile_suffix')"; exit 1 }
            print "RESULT: PASS" ;;

        generic-profile-backstop)
            # ':zdot:secrets:op' profile unset → :zdot:profile name backstop.
            zstyle ':zdot:profile' name work
            typeset -A _se
            _op_get_secrets_env && _se=("${reply[@]}")
            [[ "${_se[suffix]}" == '-work' ]] || { print "RESULT: FAIL (generic profile backstop ignored, suffix='${_se[suffix]}')"; exit 1 }
            print "RESULT: PASS" ;;

        secrets-specific-wins)
            # Explicit secrets zstyle (even a DIFFERENT name) still wins over
            # the generic backstop; empty counts as configured "none".
            zstyle ':zdot:profile' name work
            zstyle ':zdot:secrets:op' profile personal
            typeset -A _se
            _op_get_secrets_env && _se=("${reply[@]}")
            [[ "${_se[suffix]}" == '-personal' ]] || { print "RESULT: FAIL (secrets-specific zstyle did not win, got '${_se[suffix]}')"; exit 1 }
            zstyle ':zdot:secrets:op' profile ''
            _se=()
            _op_get_secrets_env && _se=("${reply[@]}")
            [[ -z "${_se[suffix]}" ]] || { print "RESULT: FAIL (explicit-empty secrets zstyle should keep suffix empty, got '${_se[suffix]}')"; exit 1 }
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(no-profile-suffix-empty profile-suffix-dash xdg-overrides consumer-pattern generic-profile-backstop secrets-specific-wins)
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