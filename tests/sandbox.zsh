#!/usr/bin/env zsh
# sandbox.zsh — run zdot in a fully isolated fake $HOME so a startup can be
# exercised end-to-end (clone, plan build, init) WITHOUT touching the real home.
#
# Why this exists
# ---------------
# zdot derives every path it reads or writes from $HOME (directly, via bare `~`,
# or via the XDG_* vars the xdg module itself sets from $HOME). So a sandbox is
# just: a throwaway directory as $HOME + ZDOTDIR + all XDG_* pointing inside it,
# launched in a scrubbed environment (`env -i`) so nothing from the caller's
# session leaks in. zsh reads its startup files from $ZDOTDIR, so a .zshrc placed
# there is the one that runs.
#
# This is the standalone (no-dotfiler) install path — the one issue #1 hit and
# the one we under-test because real machines bootstrap via `dotfiler setup`.
#
# Safety: before running we snapshot the real home's known zdot target paths and
# after running assert none changed (a tripwire). The run also lives under a
# `mktemp -d` root, so even an unanticipated write lands in the sandbox, not home.
#
# Usage:
#   tests/sandbox.zsh                 # README standalone .zshrc, clone from local repo
#   tests/sandbox.zsh --github        # clone from github.com (true cold start)
#   tests/sandbox.zsh --rc FILE       # use FILE as the sandbox .zshrc
#   tests/sandbox.zsh --keep          # don't delete the sandbox on exit
#   tests/sandbox.zsh --cmd 'zdot hook plan'   # extra command to run after init
#
# Env knobs:
#   ZDOT_SANDBOX_SOURCE=local|github  (default local)  — where to clone zdot from
#   ZDOT_VERBOSE / ZDOT_DEBUG          passed through into the sandbox shell
#
# Exit status: 0 if the sandbox shell exited 0 AND the home tripwire passed.

emulate -L zsh
setopt err_return no_unset pipe_fail

# ---------------------------------------------------------------------------
# Resolve the zdot checkout this script lives in (the clone *source* for local
# mode). :A so we get the real worktree even if tests/ is reached via a symlink.
# ---------------------------------------------------------------------------
local zdot_src="${0:A:h:h}"
local real_home="$HOME"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
local source_mode="${ZDOT_SANDBOX_SOURCE:-local}"
local keep=0
local custom_rc=""
local -a extra_cmds=()
while (( $# )); do
    case "$1" in
        --github)  source_mode="github" ;;
        --local)   source_mode="local" ;;
        --keep)    keep=1 ;;
        --rc)      shift; custom_rc="$1" ;;
        --cmd)     shift; extra_cmds+=("$1") ;;
        -h|--help) sed -n '2,30p' "$0"; return 0 ;;
        *) print -u2 "sandbox: unknown arg: $1"; return 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Build the sandbox tree
# ---------------------------------------------------------------------------
local sbx; sbx="$(mktemp -d "${TMPDIR:-/tmp}/zdot-sandbox.XXXXXX")"
local home="$sbx/home"
mkdir -p \
    "$home/.config" "$home/.cache" "$home/.local/share" "$home/.local/state"

print -r -- "sandbox:   $sbx"
print -r -- "fake HOME: $home"
print -r -- "source:    $source_mode"

# Cleanup trap (honours --keep)
_sbx_cleanup() {
    if (( keep )); then
        print -r -- "sandbox kept at: $sbx"
    else
        rm -rf "$sbx"
    fi
}
trap _sbx_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Tripwire: snapshot the real home's zdot target paths. If any of these change
# during the run, isolation has failed and we must NOT trust the result.
# We record an mtime+size signature per path (missing == "ABSENT").
# ---------------------------------------------------------------------------
local -a canaries=(
    "$real_home/.config/zdot"
    "$real_home/.config/zdot-modules"
    "$real_home/.cache/zdot"
    "$real_home/.cache/ohmyzsh"
    "$real_home/.cache/secrets"
    "$real_home/.local/share/zsh-history"
    "$real_home/.1password"
    "$real_home/.zcompdump"
    "$real_home/.zshrc"
    "$real_home/.zshenv"
)
_sig() {
    # Signature of a path: a single hash over recursive (name mtime size) lines.
    # Sensitive to creation/modification/deletion anywhere under it, but collapses
    # to one line so a large real ~/.cache/zdot doesn't flood the report.
    local p="$1"
    if [[ ! -e "$p" ]]; then print -r -- "ABSENT"; return; fi
    find "$p" -exec stat -f '%N %m %z' {} + 2>/dev/null | sort | cksum
}
typeset -A before
local c
for c in "${canaries[@]}"; do before[$c]="$(_sig "$c")"; done

# ---------------------------------------------------------------------------
# Get a fresh zdot clone INTO the sandbox config dir.
# A real `git clone` (not a copy) guarantees no dev-tree .zwc / cache leaks in.
# ---------------------------------------------------------------------------
local zdot_dest="$home/.config/zdot"
local clone_url
case "$source_mode" in
    local)  clone_url="file://$zdot_src" ;;
    github) clone_url="https://github.com/georgeharker/zdot" ;;
    *) print -u2 "sandbox: bad source mode: $source_mode"; return 2 ;;
esac
print -r -- "cloning $clone_url -> $zdot_dest"
git clone --quiet "$clone_url" "$zdot_dest"

# ---------------------------------------------------------------------------
# Write the sandbox .zshrc (ZDOTDIR points here, so this is what zsh sources).
# Default == the README "Option A: Standalone" Quick Start, verbatim.
# ---------------------------------------------------------------------------
local rc="$home/.zshrc"
if [[ -n "$custom_rc" ]]; then
    cp "$custom_rc" "$rc"
else
    cat > "$rc" <<'EOF'
# README Option A: Standalone — verbatim
source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

zdot_load_module xdg
zdot_load_module bootstrap
zdot_load_module env
zdot_load_module history
zdot_load_module brew          # macOS only; skipped if brew not found
zdot_load_module keybinds
zdot_load_module completions

zdot_init
EOF
fi
print -r -- "----- .zshrc -----"
cat "$rc"
print -r -- "------------------"

# ---------------------------------------------------------------------------
# Run an interactive zsh in the scrubbed sandbox environment.
#   env -i  : start from an empty environment (no caller leakage)
#   zsh -i  : force the *interactive* context (issue #1 is interactive-only;
#             a plain `zsh -c` builds the noninteractive plan and won't repro)
# We pass through only PATH (so git/brew/zsh resolve) and TERM.
# ---------------------------------------------------------------------------
print -r -- "===== sandbox shell output ====="
local rc_status=0
env -i \
    HOME="$home" \
    ZDOTDIR="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    PATH="$PATH" \
    TERM="${TERM:-xterm-256color}" \
    ${ZDOT_VERBOSE:+ZDOT_VERBOSE="$ZDOT_VERBOSE"} \
    ${ZDOT_DEBUG:+ZDOT_DEBUG="$ZDOT_DEBUG"} \
    zsh -i -c "${(j: ; :)extra_cmds}; exit" || rc_status=$?
print -r -- "===== end sandbox shell (exit $rc_status) ====="

# ---------------------------------------------------------------------------
# Tripwire check: did the real home change?
# ---------------------------------------------------------------------------
local tripped=0
for c in "${canaries[@]}"; do
    local after; after="$(_sig "$c")"
    if [[ "$after" != "${before[$c]}" ]]; then
        print -u2 -- "TRIPWIRE: real home path changed during sandbox run: $c"
        tripped=1
    fi
done

# Positive control: the sandbox SHOULD have been populated.
local populated=0
[[ -d "$home/.cache/zdot" ]] && populated=1

print -r -- "----- isolation report -----"
if (( tripped )); then
    print -r -- "FAIL: real \$HOME was modified (see TRIPWIRE lines above)"
else
    print -r -- "PASS: real \$HOME untouched (all ${#canaries} canaries stable)"
fi
print -r -- "sandbox cache populated: $(( populated ))  (expect 1)"
print -r -- "----------------------------"

(( tripped == 0 && rc_status == 0 )) && return 0 || return 1
