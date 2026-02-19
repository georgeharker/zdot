#!/usr/bin/env zsh
# Benchmark zsh startup time for both plugin configurations and shell modes.
#
# Usage: zsh benchmark.zsh [ITERATIONS]
#
# Compares OLD_PLUGINS=true (old) vs OLD_PLUGINS=false (new) for both
# interactive (-i) and non-interactive shells.
#
# Note: OLD_PLUGINS=true is only supported in interactive shells (.zshrc is
# sourced). Non-interactive shells source only .zshenv; the old-plugins module
# is not loaded there, so that combination is skipped.

ITERATIONS=${1:-20}
zmodload zsh/mathfunc

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse the output of TIMEFMT="%E" (format: [[h:]m:]ss.ms[s]) into seconds.
_parse_time() {
    local raw=$1
    # Remove trailing 's' if present (some zsh versions append it).
    raw=${raw%s}
    # Split on ':' — last field is always seconds.fractions.
    local parts=("${(@s/:/)raw}")
    local secs=${parts[-1]}
    local mins=${parts[-2]:-0}
    local hours=${parts[-3]:-0}
    printf "%.4f" $(( hours * 3600 + mins * 60 + secs ))
}

# Compute mean of an array of floats.
_mean() {
    local -a vals=("$@")
    local total=0
    for v in $vals; do total=$(( total + v )); done
    printf "%.3f" $(( total / ${#vals} ))
}

# Compute stddev of an array of floats (population stddev).
_stddev() {
    local -a vals=("$@")
    local n=${#vals}
    local mean=$(_mean "$@")
    local sumsq=0
    for v in $vals; do sumsq=$(( sumsq + (v - mean) * (v - mean) )); done
    printf "%.3f" $(( sqrt(sumsq / n) ))
}

# Min of an array of floats.
_min() {
    local m=$1; shift
    for v in "$@"; do (( v < m )) && m=$v; done
    printf "%.3f" $m
}

# Max of an array of floats.
_max() {
    local m=$1; shift
    for v in "$@"; do (( v > m )) && m=$v; done
    printf "%.3f" $m
}

# Run one benchmark variant.
# Usage: _bench_variant LABEL OLD_PLUGINS_VALUE INTERACTIVE_FLAG
# Sets _bench_samples (array of raw floats).
#
# Cache invalidation: touches ~/.zshrc (which load_cache() checks via :A mtime)
# then does one warmup run to rebuild cache for this variant before timing.
_bench_variant() {
    local label=$1 old_plugins=$2 interactive=$3
    local raw elapsed
    _bench_samples=()

    printf "  %-42s " "$label"

    # Bust cache then warmup (rebuilds cache for this variant).
    touch ~/.zshrc
    OLD_PLUGINS=$old_plugins zsh ${interactive:+-i} -c exit >/dev/null 2>&1

    for i in $(seq 1 $ITERATIONS); do
        # Redirect the child zsh's stdout+stderr to /dev/null; time writes to
        # stderr of the outer group, which is captured via 2>&1.
        raw=$( { TIMEFMT="%E"; time OLD_PLUGINS=$old_plugins zsh ${interactive:+-i} -c exit >/dev/null 2>&1 } 2>&1 )
        elapsed=$(_parse_time "$raw")
        _bench_samples+=($elapsed)
        printf "."
    done

    local mean=$(_mean $_bench_samples)
    printf " mean=%ss\n" "$mean"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Benchmarking zsh startup ($ITERATIONS iterations, 1 warmup per variant)"
echo ""

# Interactive shells (both old and new plugins supported)
echo "Interactive (zsh -i -c exit):"
_bench_variant "old-plugins (OLD_PLUGINS=true)"  "true"  "-i"
old_i_samples=($_bench_samples)
_bench_variant "new-plugins (OLD_PLUGINS=false)" "false" "-i"
new_i_samples=($_bench_samples)

echo ""

# Non-interactive shells (new plugins only — old-plugins module requires .zshrc)
echo "Non-interactive (zsh -c exit):"
echo "  (OLD_PLUGINS=true skipped: old-plugins module only loads via .zshrc)"
_bench_variant "new-plugins (OLD_PLUGINS=false)" "false" ""
new_ni_samples=($_bench_samples)

echo ""

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------

_diff_pct() {
    local old=$1 new=$2
    if (( old == 0 )); then
        printf "n/a"
    else
        printf "%+.1f%%" $(( (new - old) / old * 100 ))
    fi
}

_verdict() {
    local old=$1 new=$2
    if (( old == 0 )); then
        printf "n/a"
    elif (( new < old - 0.005 )); then
        printf "new faster"
    elif (( new > old + 0.005 )); then
        printf "new slower"
    else
        printf "same"
    fi
}

old_i_mean=$(_mean  $old_i_samples)
old_i_min=$( _min   $old_i_samples)
old_i_max=$( _max   $old_i_samples)
old_i_sd=$(  _stddev $old_i_samples)

new_i_mean=$(_mean  $new_i_samples)
new_i_min=$( _min   $new_i_samples)
new_i_max=$( _max   $new_i_samples)
new_i_sd=$(  _stddev $new_i_samples)

new_ni_mean=$(_mean  $new_ni_samples)
new_ni_min=$( _min   $new_ni_samples)
new_ni_max=$( _max   $new_ni_samples)
new_ni_sd=$(  _stddev $new_ni_samples)

fmt="%-20s  %8s  %8s  %8s  %8s  %8s  %s\n"
printf "$fmt" "Mode" "variant" "mean" "min" "max" "stddev" "verdict"
printf "$fmt" "--------------------" "--------" "--------" "--------" "--------" "--------" "----------"
printf "$fmt" "interactive" "old" "${old_i_mean}s" "${old_i_min}s" "${old_i_max}s" "${old_i_sd}s" ""
printf "$fmt" "" "new" "${new_i_mean}s" "${new_i_min}s" "${new_i_max}s" "${new_i_sd}s" \
    "$(_verdict $old_i_mean $new_i_mean) ($(_diff_pct $old_i_mean $new_i_mean))"
printf "$fmt" "non-interactive" "new" "${new_ni_mean}s" "${new_ni_min}s" "${new_ni_max}s" "${new_ni_sd}s" "n/a"
echo ""
