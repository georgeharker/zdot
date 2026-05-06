#!/usr/bin/env zsh
# Benchmark zsh startup time across all four shell contexts.
#
# Usage: zdot bench [--compare] [ITERATIONS]
#
# The four contexts cover every combination of login/non-login and
# interactive/non-interactive, because zdot can bootstrap from .zshenv,
# .zprofile, or .zshrc depending on context:
#
#   interactive   non-login    zsh -i  -c exit
#   interactive   login        zsh -il -c exit
#   non-interactive non-login  zsh     -c exit
#   non-interactive login      zsh -l  -c exit
#
# Flags:
#
#   --compare   Enable A/B comparison mode.  Runs each context twice:
#               once with ZDOT_OLD_SETUP=true and once with
#               ZDOT_OLD_SETUP=false.  Prints a verdict (new faster /
#               new slower / same) per context.
#               Requires your dotfiles to honour ZDOT_OLD_SETUP.
#
#   ITERATIONS  Positional integer argument — number of timed runs per
#               variant (default: 20).  Can appear before or after --compare.
#
# Environment variables:
#
#   ZDOTDIR     Standard zsh variable.  When set, the benchmark touches
#               $ZDOTDIR/.zshrc to bust the zdot startup cache before each
#               variant's warmup run.  Defaults to $HOME.
#
#   ZDOT_OLD_SETUP   Your dotfiles' A/B flag.  Only used when --compare is
#               passed.  The benchmark sets it to "true" (old setup) and
#               "false" (new setup) in the child environment.  It is never
#               read from the caller's environment — pass --compare instead.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ITERATIONS=20
_BENCH_COMPARE=0

for _arg in "$@"; do
    case $_arg in
        --compare) _BENCH_COMPARE=1 ;;
        <->) ITERATIONS=$_arg ;;
        *) echo "Usage: zdot bench [--compare] [ITERATIONS]" >&2; exit 1 ;;
    esac
done
unset _arg

# Resolve the zshrc path used for cache busting.
_BENCH_ZSHRC="${ZDOTDIR:-${HOME}}/.zshrc"

zmodload zsh/mathfunc

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse the output of TIMEFMT="%E" (format: [[h:]m:]ss.ms[s]) into seconds.
_parse_time() {
    local raw=$1
    raw=${raw%s}
    local parts=("${(@s/:/)raw}")
    local secs=${parts[-1]}
    local mins=${parts[-2]:-0}
    local hours=${parts[-3]:-0}
    printf "%.4f" $(( hours * 3600 + mins * 60 + secs ))
}

_mean() {
    local -a vals=("$@")
    local total=0
    for v in $vals; do total=$(( total + v )); done
    printf "%.3f" $(( total / ${#vals} ))
}

_stddev() {
    local -a vals=("$@")
    local n=${#vals}  # shuck: ignore=C001
    local mean=$(_mean "$@")
    local sumsq=0
    for v in $vals; do sumsq=$(( sumsq + (v - mean) * (v - mean) )); done
    printf "%.3f" $(( sqrt(sumsq / n) ))
}

_min() {
    local m=$1; shift
    for v in "$@"; do (( v < m )) && m=$v; done
    printf "%.3f" $m
}

_max() {
    local m=$1; shift
    for v in "$@"; do (( v > m )) && m=$v; done
    printf "%.3f" $m
}

# Run one benchmark variant.
# Usage: _bench_variant LABEL ZSH_FLAGS [ZDOT_OLD_SETUP_VAL]
#   LABEL              Display name printed before the progress dots.
#   ZSH_FLAGS          Flags passed to zsh (e.g. "-i", "-il", "-l", "").
#   ZDOT_OLD_SETUP_VAL Optional.  When provided, sets ZDOT_OLD_SETUP=VAL
#                      in the child environment.
#
# Sets _bench_samples (array of floats) on return.
# Touches _BENCH_ZSHRC before warmup to bust the zdot cache.
_bench_variant() {
    local label=$1 zsh_flags=$2 old_setup_val=${3:-}
    local raw elapsed
    _bench_samples=()

    # Build the command as an array so env vars and flags are passed cleanly
    # without going through eval (which breaks the TIMEFMT/time capture).
    local -a cmd
    if [[ -n $old_setup_val ]]; then
        cmd=(env ZDOT_OLD_SETUP=$old_setup_val zsh)
    else
        cmd=(zsh)
    fi
    [[ -n $zsh_flags ]] && cmd+=("${(s: :)zsh_flags}")
    cmd+=(-c exit)

    printf "  %-50s " "$label"

    # Bust cache then warmup to rebuild cache for this variant.
    touch "$_BENCH_ZSHRC"
    "${cmd[@]}" >/dev/null 2>&1

    for i in $(seq 1 $ITERATIONS); do
        # Suppress child stdout and stderr so they don't contaminate the capture.
        # time writes TIMEFMT output to the enclosing shell's stderr, which the
        # outer { } 2>&1 then captures into $raw.
        raw=$( { TIMEFMT="%E"; time "${cmd[@]}" >/dev/null 2>/dev/null } 2>&1 )  # shuck: ignore=C001
        elapsed=$(_parse_time "$raw")
        _bench_samples+=($elapsed)
        printf "."
    done

    local mean=$(_mean $_bench_samples)
    printf " mean=%ss\n" "$mean"
}

# Summarise a set of samples: mean/min/max/stddev.
_summarise() {
    local -a s=("$@")
    echo "$(_mean $s) $(_min $s) $(_max $s) $(_stddev $s)"
}

# ---------------------------------------------------------------------------
# Context definitions: (label, zsh_flags)
# ---------------------------------------------------------------------------

_context_labels=(
    "interactive non-login"
    "interactive login"
    "non-interactive non-login"
    "non-interactive login"
)
_context_flags=(
    "-i"
    "-il"
    ""
    "-l"
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Benchmarking zsh startup ($ITERATIONS iterations, 1 warmup per variant)"
echo "  zshrc for cache busting: $_BENCH_ZSHRC"
(( _BENCH_COMPARE )) && echo "  mode: A/B compare (ZDOT_OLD_SETUP=true vs false)"
echo ""

if (( _BENCH_COMPARE )); then
    # -----------------------------------------------------------------------
    # Comparison mode: each context run twice, old vs new
    # -----------------------------------------------------------------------

    typeset -A old_means new_means old_mins new_mins old_maxs new_maxs old_sds new_sds

    for i in $(seq 1 ${#_context_labels}); do
        local ctx="${_context_labels[$i]}"
        local flags="${_context_flags[$i]}"

        echo "${ctx}:"
        _bench_variant "  old (ZDOT_OLD_SETUP=true)  [${ctx}]" "$flags" "true"
        old_means[$ctx]=$(_mean $_bench_samples)
        old_mins[$ctx]=$( _min  $_bench_samples)
        old_maxs[$ctx]=$( _max  $_bench_samples)
        old_sds[$ctx]=$(  _stddev $_bench_samples)

        _bench_variant "  new (ZDOT_OLD_SETUP=false) [${ctx}]" "$flags" "false"
        new_means[$ctx]=$(_mean $_bench_samples)
        new_mins[$ctx]=$( _min  $_bench_samples)
        new_maxs[$ctx]=$( _max  $_bench_samples)
        new_sds[$ctx]=$(  _stddev $_bench_samples)
        echo ""
    done

    _diff_pct() {
        local old=$1 new=$2
        (( old == 0 )) && { printf "n/a"; return }
        printf "%+.1f%%" $(( (new - old) / old * 100 ))
    }

    _verdict() {
        local old=$1 new=$2
        (( old == 0 )) && { printf "n/a"; return }
        if   (( new < old - 0.005 )); then printf "new faster"
        elif (( new > old + 0.005 )); then printf "new slower"
        else printf "same"
        fi
    }

    fmt="%-30s  %-3s  %8s  %8s  %8s  %8s  %s\n"
    printf "$fmt" "Context" "var" "mean" "min" "max" "stddev" "verdict"
    printf "$fmt" "------------------------------" "---" "--------" "--------" "--------" "--------" "----------"

    for i in $(seq 1 ${#_context_labels}); do
        local ctx="${_context_labels[$i]}"
        printf "$fmt" "$ctx" "old" \
            "${old_means[$ctx]}s" "${old_mins[$ctx]}s" "${old_maxs[$ctx]}s" "${old_sds[$ctx]}s" ""
        printf "$fmt" "" "new" \
            "${new_means[$ctx]}s" "${new_mins[$ctx]}s" "${new_maxs[$ctx]}s" "${new_sds[$ctx]}s" \
            "$(_verdict ${old_means[$ctx]} ${new_means[$ctx]}) ($(_diff_pct ${old_means[$ctx]} ${new_means[$ctx]}))"
    done
    echo ""

else
    # -----------------------------------------------------------------------
    # Default mode: all four contexts, no A/B
    # -----------------------------------------------------------------------

    typeset -A means mins maxs sds

    for i in $(seq 1 ${#_context_labels}); do
        local ctx="${_context_labels[$i]}"
        local flags="${_context_flags[$i]}"
        _bench_variant "$ctx" "$flags"
        means[$ctx]=$(_mean $_bench_samples)
        mins[$ctx]=$( _min  $_bench_samples)
        maxs[$ctx]=$( _max  $_bench_samples)
        sds[$ctx]=$(  _stddev $_bench_samples)
    done

    echo ""
    fmt="%-30s  %8s  %8s  %8s  %8s\n"
    printf "$fmt" "Context" "mean" "min" "max" "stddev"
    printf "$fmt" "------------------------------" "--------" "--------" "--------" "--------"
    for i in $(seq 1 ${#_context_labels}); do
        local ctx="${_context_labels[$i]}"
        printf "$fmt" "$ctx" "${means[$ctx]}s" "${mins[$ctx]}s" "${maxs[$ctx]}s" "${sds[$ctx]}s"
    done
    echo ""
fi
