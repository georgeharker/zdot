#!/usr/bin/env zsh
# Profile zsh startup for old-plugins vs new-plugins using zprof.
#
# Usage: zsh scripts/profile.zsh [old|new|both] [--warm]
#
# Creates a temporary ZDOTDIR with a wrapper .zshrc that injects
# zmodload zsh/zprof before sourcing the real ~/.zshrc, then calls
# zprof at the end. Captures and displays the top hot functions.
#
# --warm  Symlink real compdump files into the temp ZDOTDIR so that
#         zdot_compdump_needs_refresh returns false and compinit is
#         skipped — simulating a normal (non-first) shell startup.

VARIANT=both
WARM=false

for arg in "$@"; do
    case $arg in
        --warm) WARM=true ;;
        old|new|both) VARIANT=$arg ;;
        *) echo "Usage: $0 [old|new|both] [--warm]" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Setup: temp ZDOTDIR with wrapper .zshrc
# ---------------------------------------------------------------------------

_make_zdotdir() {
    local old_plugins=$1
    local tmpdir=$(mktemp -d)

    cat > "$tmpdir/.zshrc" <<WRAPPER
zmodload zsh/zprof
OLD_PLUGINS=${old_plugins}
ZDOTDIR="\${HOME}"
source "\${HOME}/.zshrc"
zprof
WRAPPER

    # zsh looks for .zshenv in ZDOTDIR too — provide a no-op so it doesn't
    # fall back to the real one and double-source things.
    touch "$tmpdir/.zshenv"

    if [[ "$WARM" == true ]]; then
        # Symlink real compdump files so zdot_compdump_needs_refresh finds
        # them at $ZDOTDIR/.zcompdump-* and skips compinit (warm-start sim).
        local f
        for f in "${HOME}/.zcompdump"*(N); do
            ln -s "$f" "$tmpdir/$(basename $f)"
        done
    fi

    echo "$tmpdir"
}

_run_profile() {
    local label=$1 old_plugins=$2
    local tmpdir=$(_make_zdotdir $old_plugins)

    # Touch ~/.zshrc so the cache mtime check sees it as newer than any
    # existing cache built under a different OLD_PLUGINS value, forcing
    # cache invalidation and avoiding stale hook registrations.
    touch "${HOME}/.zshrc"

    echo "========================================"
    echo "  Profile: $label"
    echo "========================================"
    ZDOTDIR="$tmpdir" zsh -i -c exit 2>&1
    echo ""

    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

warm_label=""
[[ "$WARM" == true ]] && warm_label=" [warm]"

case $VARIANT in
    old)
        _run_profile "old-plugins (OLD_PLUGINS=true)${warm_label}"  "true"
        ;;
    new)
        _run_profile "new-plugins (OLD_PLUGINS=false)${warm_label}" "false"
        ;;
    both)
        _run_profile "old-plugins (OLD_PLUGINS=true)${warm_label}"  "true"
        _run_profile "new-plugins (OLD_PLUGINS=false)${warm_label}" "false"
        ;;
    *)
        echo "Usage: $0 [old|new|both] [--warm]" >&2
        exit 1
        ;;
esac
