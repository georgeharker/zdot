#!/usr/bin/env zsh
# Profile zsh startup using zprof to show which functions are slowest.
#
# Usage: zdot profile [--warm]
#
# Creates a temporary ZDOTDIR containing a wrapper .zshrc that loads
# zprof before sourcing the real .zshrc, then prints the function-level
# timing breakdown.
#
# If you want to compare old vs new setups, set ZDOT_OLD_SETUP in the
# environment before running and run twice:
#
#   ZDOT_OLD_SETUP=true  zdot profile
#   ZDOT_OLD_SETUP=false zdot profile
#
# Options:
#
#   --warm   Symlink existing compdump files into the temp ZDOTDIR so
#            compinit is skipped, simulating a normal (non-first) startup.
#
# Environment variables:
#
#   ZDOTDIR        Standard zsh variable.  Defaults to $HOME.  The real
#                  .zshrc is sourced from $ZDOTDIR/.zshrc.  Compdump files
#                  are looked up alongside it when --warm is used.
#
#   ZDOT_OLD_SETUP Your dotfiles' A/B flag.  If your dotfiles honour this
#                  variable, set it before invoking zdot profile to control
#                  which setup is profiled.  The profiler passes it through
#                  unchanged into the child shell.

WARM=false

for _arg in "$@"; do
    case $_arg in
        --warm) WARM=true ;;
        *) echo "Usage: zdot profile [--warm]" >&2; exit 1 ;;
    esac
done
unset _arg

_PROF_ZSHRC="${ZDOTDIR:-${HOME}}/.zshrc"
_PROF_ZDOTDIR_REAL="${ZDOTDIR:-${HOME}}"

# ---------------------------------------------------------------------------
# Build temp ZDOTDIR with zprof wrapper
# ---------------------------------------------------------------------------

_make_zdotdir() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Wrapper .zshrc:
    #   1. Loads zprof instrumentation before anything else.
    #   2. Resets ZDOTDIR to the real location so any nested zsh invocations
    #      inside the real .zshrc don't inherit the temp dir.
    #   3. Passes ZDOT_OLD_SETUP through if it was set by the caller.
    #   4. Sources the real .zshrc.
    #   5. Dumps the profile.
    cat > "$tmpdir/.zshrc" <<WRAPPER
zmodload zsh/zprof
ZDOTDIR="${_PROF_ZDOTDIR_REAL}"
${ZDOT_OLD_SETUP+ZDOT_OLD_SETUP="${ZDOT_OLD_SETUP}"}
source "${_PROF_ZSHRC}"
zprof
WRAPPER

    # Provide a no-op .zshenv so zsh does not fall back to the real one and
    # double-source any zdot bootstrap that lives there.
    touch "$tmpdir/.zshenv"

    if [[ "$WARM" == true ]]; then
        local f
        for f in "${_PROF_ZDOTDIR_REAL}/.zcompdump"*(N); do
            ln -s "$f" "$tmpdir/$(basename $f)"
        done
    fi

    echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

warm_label=""
[[ "$WARM" == true ]] && warm_label=" [warm]"

old_setup_label=""
[[ -n "${ZDOT_OLD_SETUP:-}" ]] && old_setup_label=" (ZDOT_OLD_SETUP=${ZDOT_OLD_SETUP})"

tmpdir=$(_make_zdotdir)

# Touch the real .zshrc to bust any zdot cache built under different env.
touch "$_PROF_ZSHRC"

echo "========================================"
echo "  Profile${old_setup_label}${warm_label}"
echo "========================================"
ZDOTDIR="$tmpdir" zsh -i -c exit 2>&1
echo ""

rm -rf "$tmpdir"
