# core/plugin-update.zsh
# Background-mode update reminders for plugins zdot manages.
#
# Sourced unconditionally from zdot.zsh so the file gets compiled to .zwc
# alongside the rest of core. The file defines functions only — NO hook
# registration, NO zstyle reads, NO state-dir creation at source time.
# modules/plugins/plugins.zsh is responsible for wiring this into the
# hook system (and any module that wants a similar nag UI for its own
# updates can register the same engine functions on its own cadence).
#
# Distinct from core/update.zsh (zdot self-update):
#   - core/update.zsh tracks ZDOT_REPO itself (and dotfiler integration).
#   - This file scans every git-backed plugin in _ZDOT_PLUGINS_PATH on its
#     own cadence and prompts the user to fast-forward those that have a
#     new upstream HEAD. Reuses zdot_check_plugin_updates' primitives
#     (zdot_plugin_repo / zdot_plugin_name) for bundle-aware dedupe and
#     delegates the apply step to zdot_update_plugin.
#
# Opt-in. Default mode is 'disabled' — zero overhead until configured.
#
# zstyle reference:
#   zstyle ':zdot:plugin-update' mode        disabled  # disabled | reminder | prompt
#   zstyle ':zdot:plugin-update' frequency   14400     # seconds between checks (4h)
#
# Flow:
#   1. _zdot_plugin_update_main runs as a regular (non-deferred) interactive
#      hook. The actual network I/O is isolated in a `&!` background subshell,
#      so the parent shell never blocks on git fetch — there's no need for
#      hook-level defer too. If due and not locked, it forks the scan, which
#      writes results atomically to a pending file. The parent registers a
#      precmd hook to surface them and returns immediately.
#   2. _zdot_plugin_update_precmd fires before each prompt. While the scan
#      is in flight it prints a one-shot faded "checking…" notice; once the
#      pending file lands it consumes it and either prints a faded
#      "no plugin updates" line, logs an error, or presents the results:
#      the y/n prompt only if they were waiting before the user ran any
#      command, otherwise a non-blocking notice (stdin untouched).
#   3. _zdot_plugin_update_prompt_and_upgrade renders the summary, gates on
#      _zdot_plugin_update_has_typed_input (auto-skips as 'n' if the user
#      is mid-typing), and on Y runs git pull --ff-only per plugin.

# ============================================================================
# State paths and config
# ============================================================================

_zdot_plugin_update_state_dir() {
    print -r -- "${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugin-update"
}
# _zdot_plugin_update_pending_path — per-shell pending file, keyed by PID.
# Scan results belong to the shell that spawned them, so another window's
# precmd can no longer consume them and pop a presentation (with its blocking
# [Y/n] read) there. zsh keeps $$ as the parent shell's PID inside
# subshells, so the parent, the deferred scan subshell, and the precmd hook
# all agree on the name. (Legacy shared name was "pending"; a stale legacy
# file is harmless — never consumed, and the rate limit gates the next real
# scan.)
_zdot_plugin_update_pending_path() {
    print -r -- "$(_zdot_plugin_update_state_dir)/pending.$$"
}

# _zdot_plugin_update_pending_owner_alive <pending-file> — 0 when the shell
# that owns the file (PID suffix) is still running. Such a file is NOT a
# leftover: its owner is merely busy in a foreground command and will
# consume it at its next prompt. `kill -0` is a builtin, so this costs no
# fork. A PID reused by an unrelated process reads as alive, which errs on
# the side of leaving the file alone.
_zdot_plugin_update_pending_owner_alive() {
    emulate -L zsh
    setopt local_options
    local pid=${1##*/pending.}
    [[ $pid == <-> ]] || return 1
    kill -0 $pid 2>/dev/null
}

# _zdot_plugin_update_pending_leftovers <own-pending> — set reply to the
# pending files in <own-pending>'s directory left by shells that have died,
# excluding <own-pending> itself and in-progress `.tmp` writes. Files of
# shells that died over an hour ago are deleted instead of returned: stale
# enough to let the rate limit govern the next real scan. Runs on the
# startup path, so it is fork-free: the directory comes from the argument,
# and the glob qualifier `mh+1` does the age test without `date`/`stat`.
_zdot_plugin_update_pending_leftovers() {
    emulate -L zsh
    setopt local_options extended_glob
    # Used via ${(b)exclude} below, which the linter does not see.
    # shuck: disable=C001
    local exclude=$1
    local dir=${exclude:h}
    local -a candidates stale
    candidates=( $dir/pending.<->(N) )
    stale=( $dir/pending.<->(Nmh+1) )
    candidates=( ${candidates:#${(b)exclude}} )
    stale=( ${stale:#${(b)exclude}} )
    local f
    reply=()
    for f in "${candidates[@]}"; do
        if ! _zdot_plugin_update_pending_owner_alive "$f"; then
            reply+=( "$f" )
        fi
    done
    for f in "${stale[@]}"; do
        (( ${reply[(Ie)$f]} )) || continue
        rm -f "$f" 2>/dev/null
        reply=( ${reply:#${(b)f}} )
    done
    return 0
}
_zdot_plugin_update_stamp_path()   { print -r -- "$(_zdot_plugin_update_state_dir)/last_check" }
_zdot_plugin_update_lock_path()    { print -r -- "$(_zdot_plugin_update_state_dir)/lock.d" }

# Ensure the state directory exists. Cheap and idempotent; safe to call
# at every entry point that may read or write a state file.
_zdot_plugin_update_ensure_state_dir() {
    local dir=$(_zdot_plugin_update_state_dir)
    [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
}

_zdot_plugin_update_mode() {
    local m
    zstyle -s ':zdot:plugin-update' mode m
    print -r -- "${m:-disabled}"
}

_zdot_plugin_update_frequency() {
    local f
    zstyle -s ':zdot:plugin-update' frequency f
    print -r -- "${f:-14400}"
}

_zdot_plugin_update_mtime() {
    local target=$1 result
    if result=$(stat -f %m "$target" 2>/dev/null) && [[ -n $result ]]; then
        print -r -- "$result"; return
    fi
    if result=$(stat -c %Y "$target" 2>/dev/null) && [[ -n $result ]]; then
        print -r -- "$result"; return
    fi
    print -r -- 0
}

# ============================================================================
# Guards / rate limit / lock
# ============================================================================

_zdot_plugin_update_should_run() {
    emulate -L zsh
    setopt local_options
    [[ "$(_zdot_plugin_update_mode)" != disabled ]] || return 1
    zdot_interactive || return 1
    [[ $TERM != dumb ]] || return 1
    # Note: no -t 0 / -t 1 checks here. We're called from a deferred-dispatch
    # context (zsh-defer) where stdin is redirected so it doesn't race with
    # zle for input. The bg fetch doesn't need a TTY; the y/n prompt path
    # checks for one independently before reading a key.
    return 0
}

# _zdot_plugin_update_is_due — true if at least $frequency seconds have
# elapsed since the last LAST_EPOCH stored in the timestamp file. Returns
# 0 (true) when the file is missing or unreadable so a fresh install
# checks immediately rather than deferring four hours.
_zdot_plugin_update_is_due() {
    emulate -L zsh
    setopt local_options
    local stamp=$(_zdot_plugin_update_stamp_path)
    [[ -f $stamp ]] || return 0
    local LAST_EPOCH=0
    source "$stamp" 2>/dev/null
    local interval=$(_zdot_plugin_update_frequency)
    local now=$(date +%s)
    (( now - LAST_EPOCH >= interval ))
}

# _zdot_plugin_update_write_timestamp [exit_status [error]]
# Content-based stamp file matching dotfiler/zdot self-update style. Writes
# LAST_EPOCH always; EXIT_STATUS and ERROR only when the args are non-empty.
# The bg subshell's happy path calls this with status=0; the trap calls it
# with status=1 if the scan was interrupted before pending was written, so
# subsequent shells in the same rate-limit window don't re-pound the network.
_zdot_plugin_update_write_timestamp() {
    emulate -L zsh
    setopt local_options
    local _exit_status=${1:-} _error=${2:-}
    local _ts=$(_zdot_plugin_update_stamp_path)
    _zdot_plugin_update_ensure_state_dir
    {
        print -- "LAST_EPOCH=$(date +%s)"
        if [[ -n "$_exit_status" ]]; then
            print -- "EXIT_STATUS=$_exit_status"
        fi
        if [[ -n "$_error" ]]; then
            print -- "ERROR=${_error//\'/\'\\\'\'}"
        fi
    } >| "$_ts" 2>/dev/null
    return 0
}

_zdot_plugin_update_acquire_lock() {
    emulate -L zsh
    setopt local_options
    _zdot_plugin_update_ensure_state_dir
    local lock=$(_zdot_plugin_update_lock_path)
    if [[ -d $lock ]]; then
        local mtime=$(_zdot_plugin_update_mtime "$lock")
        local now=$(date +%s)
        (( now - mtime > 300 )) && rmdir "$lock" 2>/dev/null
    fi
    mkdir "$lock" 2>/dev/null
}

_zdot_plugin_update_release_lock() {
    rmdir "$(_zdot_plugin_update_lock_path)" 2>/dev/null
}

# ============================================================================
# Scan: per-plugin upstream-HEAD comparison
# ============================================================================

# _zdot_plugin_update_collect — emit one TSV row per outdated plugin:
#   spec<TAB>label<TAB>current_short_sha<TAB>upstream_short_sha
#
# Mirrors zdot_check_plugin_updates' primitives so we stay bundle-aware:
# both _ZDOT_PLUGINS_ORDER and _ZDOT_BUNDLE_REPOS are walked, dedupe is by
# physical repo dir (zdot_plugin_repo), display name is zdot_plugin_name.
# git fetch primes the eventual pull (via zdot_update_plugin) with no
# extra network round-trip.
#
# Two independent signals are emitted per plugin:
#   1. Ref drift (direction-agnostic): the clone is checked out somewhere other
#      than where its spec says — covers every flip (unpin→default, default→pin,
#      pin→pin), not just the unpin case that first surfaced the bug. Detected
#      locally (no fetch), for pinned AND unpinned specs.
#   2. Behind upstream: an unpinned plugin that IS on its default branch but
#      has new upstream commits (the ordinary update nag).
#
# Skips silently:
#   - Bundles with no backing repo (zdot_plugin_repo returns 1).
#   - Pinned plugins that ARE on their pin — not nagged for upstream movement;
#     the user explicitly chose that ref. (A pinned plugin off its ref is still
#     surfaced as drift.)
#   - Missing repos, non-git dirs, no upstream tracked, fetch failures.
_zdot_plugin_update_collect() {
    emulate -L zsh
    setopt local_options

    local -a specs=( "${_ZDOT_PLUGINS_ORDER[@]}" "${_ZDOT_BUNDLE_REPOS[@]}" )
    local -A seen
    local spec bare version repo_dir label current upstream cur_branch want reconciled want_commit head_commit

    for spec in "${specs[@]}"; do
        bare=$spec
        version=""
        if [[ $bare == *@* ]]; then
            version=${bare##*@}
            bare=${bare%@*}
        fi
        if [[ -z "$version" && -n "${_ZDOT_PLUGINS_VERSION[$bare]:-}" ]]; then
            version=${_ZDOT_PLUGINS_VERSION[$bare]}
        fi

        zdot_plugin_repo "$bare" 2>/dev/null || continue
        repo_dir=$REPLY
        zdot_plugin_name "$bare"
        label=$REPLY

        (( ${+seen[$repo_dir]} )) && continue
        # shuck: disable=C001
        seen[$repo_dir]=1

        [[ -d "$repo_dir/.git" ]] || continue

        # ── Drift check (direction-agnostic, local-only) ────────────────────
        # Is the clone actually checked out where its spec wants it? The
        # reconcile itself happens in zdot_update_plugin (the apply step); here
        # we only surface drift so the nag fires. Local-only (branch name for
        # unpinned, resolved commit for pinned) — frozen pins never fetch.
        cur_branch=$(command git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null)
        want=""; reconciled=0
        if [[ -n "$version" ]]; then
            # Pinned: reconciled iff HEAD is at the commit the pin resolves to
            # (covers branch, tag, and sha pins, detached or not).
            want=$version
            want_commit=$(command git -C "$repo_dir" rev-parse --verify -q "${version}^{commit}" 2>/dev/null) \
                || want_commit=$(command git -C "$repo_dir" rev-parse --verify -q "origin/${version}^{commit}" 2>/dev/null)
            head_commit=$(command git -C "$repo_dir" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)
            [[ -n "$want_commit" && "$want_commit" == "$head_commit" ]] && reconciled=1
        elif _zdot_plugin_default_ref "$repo_dir"; then
            # Unpinned: must be ON the default branch so pulls track it.
            want=$REPLY
            [[ "$cur_branch" == "$want" ]] && reconciled=1
        else
            # Can't determine the default branch — don't cry drift; the upstream
            # nag below is skipped too (no resolvable @{u}).
            reconciled=1
        fi

        if (( ! reconciled )); then
            current=$(command git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
            print -r -- "${bare}"$'\t'"${label}"$'\t'"${cur_branch:-${current:-detached}}"$'\t'"${want}"
            continue
        fi

        # On the right ref. Pinned specs are frozen by the user's choice — don't
        # nag for upstream movement.
        [[ -n "$version" ]] && continue

        # ── Behind-upstream check (unpinned, on default branch) ─────────────
        # git fetch primes the eventual pull (via zdot_update_plugin).
        command git -C "$repo_dir" fetch --quiet 2>/dev/null
        current=$(command git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
        upstream=$(command git -C "$repo_dir" rev-parse --short '@{u}' 2>/dev/null)
        [[ -n "$current" && -n "$upstream" ]] || continue
        [[ "$current" != "$upstream" ]] || continue

        print -r -- "${bare}"$'\t'"${label}"$'\t'"${current}"$'\t'"${upstream}"
    done
}

# ============================================================================
# Typed-input guard (zselect-based stdin poll)
# Pattern from dotfiler's _update_core_has_typed_input, which credits
# Philippe Troin: https://zsh.org/mla/users/2022/msg00062.html
# ============================================================================

_zdot_plugin_update_has_typed_input() {
    emulate -L zsh
    setopt local_options
    [[ -t 0 ]] || return 1
    zmodload zsh/zselect 2>/dev/null || return 1
    local REPLY token
    _zdot_plugin_update_tty_apply -icanon || return 1
    token=$REPLY
    {
        zselect -t 0 -r 0
        return $?
    } always {
        _zdot_plugin_update_tty_undo "$token"
    }
}

# ============================================================================
# tty mode changes: compare-then-restore
# ============================================================================
#
# Every tty change here is made and undone synchronously at a prompt (the
# typed-input peek, the [Y/n] key read), so the shell is in the foreground.
# Still, the undo never blindly replays a `stty -g` snapshot. If the tty no
# longer matches the state we left it in, something else changed it while we
# held it, and replaying the snapshot would silently revert that change. In
# that case only the flags we changed are flipped back.

# _zdot_plugin_update_tty_apply <mode…> — switch the tty flags named by
# <mode…> (each `echo`/`-echo`/`icanon`/`-icanon`; `-icanon` also forces
# `min 1 time 0` so a blocking `read -k` returns on the first byte) and set
# REPLY to an opaque token for _zdot_plugin_update_tty_undo: the tty before,
# the tty as we left it, and the minimal flag list reversing only what we
# changed. Returns 1 with the tty untouched when stdin isn't a TTY or its
# modes can't be read.
_zdot_plugin_update_tty_apply() {
    emulate -L zsh
    setopt local_options
    REPLY=
    [[ -t 0 ]] || return 1
    local raw
    raw=$(stty -a 2>/dev/null) || return 1
    # Normalise both BSD ("lflags: icanon … echo …") and GNU ("… icanon …;")
    # layouts into space-delimited tokens so " echo " can't match "echoe".
    local cur=" ${raw//[;$'\n'$'\t']/ } "
    local m flag cbreak=0
    local -a apply undo
    for m in "$@"; do
        flag=${m#-}
        [[ $m == -icanon ]] && cbreak=1
        if [[ $m == -* ]]; then
            [[ $cur == *" $flag "* ]] || continue
            apply+=( -$flag ); undo+=( $flag )
        else
            [[ $cur == *" -$flag "* ]] || continue
            apply+=( $flag ); undo+=( -$flag )
        fi
    done
    (( cbreak )) && apply+=( min 1 time 0 )
    local before after
    before=$(stty -g 2>/dev/null) || return 1
    stty "${apply[@]}" 2>/dev/null
    after=$(stty -g 2>/dev/null)
    REPLY="${before}"$'\t'"${after}"$'\t'"${undo[*]}"
    return 0
}

# _zdot_plugin_update_tty_undo <token> — reverse a tty_apply: the saved
# snapshot verbatim if the tty is exactly as we left it, otherwise only the
# flags we changed.
_zdot_plugin_update_tty_undo() {
    emulate -L zsh
    setopt local_options
    [[ -n $1 && -t 0 ]] || return 0
    local -a parts
    parts=( "${(@ps:\t:)1}" )
    local before=$parts[1] after=$parts[2] undo=$parts[3] now
    now=$(stty -g 2>/dev/null) || return 0
    if [[ -n $before && $now == "$after" ]]; then
        stty "$before" 2>/dev/null
    elif [[ -n $undo ]]; then
        stty ${=undo} 2>/dev/null
    fi
    return 0
}

# ============================================================================
# p10k instant-prompt awareness
# ============================================================================
#
# p10k draws a synthetic "instant prompt" before zsh init finishes. Printing
# during that window corrupts its screen buffer. Same mitigation as zsh-defer:
# defer one precmd cycle when instant-prompt is active so we land after the
# real prompt is drawn.

_zdot_plugin_update_p10k_active() {
    case ${POWERLEVEL9K_INSTANT_PROMPT:-} in
        ''|off) return 1 ;;
        *)      return 0 ;;
    esac
}

# ============================================================================
# UI: render summary and the y/n prompt
# ============================================================================

_zdot_plugin_update_color_enabled() {
    [[ -z ${NO_COLOR-} ]] || return 1
    [[ -t 1 ]] || return 1
    [[ $TERM != dumb ]] || return 1
    return 0
}

_zdot_plugin_update_render_summary() {
    emulate -L zsh
    setopt local_options
    local -a lines=( "$@" )
    local n=${#lines}

    if _zdot_plugin_update_color_enabled; then
        print -P -- "%B%F{cyan}▲ ${n} plugin update$( (( n == 1 )) || print s ) available%f%b"
    else
        print -- "▲ ${n} plugin update$( (( n == 1 )) || print s ) available"
    fi
    print

    local line label cur up
    local max_label=0
    for line in "${lines[@]}"; do
        label=${${(s:	:)line}[2]}
        (( ${#label} > max_label )) && max_label=${#label}
    done
    (( max_label = max_label < 8 ? 8 : max_label ))

    local pad spaces
    for line in "${lines[@]}"; do
        label=${${(s:	:)line}[2]}
        cur=${${(s:	:)line}[3]}
        up=${${(s:	:)line}[4]}
        pad=$(( max_label - ${#label} ))
        (( pad < 0 )) && pad=0
        spaces=${(l:$pad:: :)}
        if _zdot_plugin_update_color_enabled; then
            print -P -- "    %F{default}${label//\%/%%}%f${spaces}  %F{yellow}${cur}%f %F{244}→%f %F{green}${up}%f"
        else
            print -- "    ${label}${spaces}  ${cur} → ${up}"
        fi
    done
    print
}

# Read one keypress from stdin in cbreak mode. Returns the key (lowercased)
# on stdout; default if read fails or the key isn't in $valid.
_zdot_plugin_update_read_key() {
    emulate -L zsh
    setopt local_options
    local valid=$1 default=$2 key
    local REPLY
    if _zdot_plugin_update_tty_apply -icanon echo; then
        # The token is `stty -g` strings, flags, and tabs — never a single
        # quote — so it is safe to embed (expanding it now is the point).
        # shuck: disable=C008
        trap "_zdot_plugin_update_tty_undo '$REPLY'" EXIT
    fi
    if ! read -k 1 -u 0 key; then
        # EOF (Ctrl-D, closed stdin) must DECLINE, not accept: only an
        # explicit valid key — or the [Y/n] Enter default — accepts. Mirrors
        # update-impl's `read ... || _ans=n`.
        if [[ $valid == *n* ]]; then
            print -r -- n
        else
            print -r -- "$default"
        fi
        return
    fi
    print >&2
    # Enter / empty → take the default (e.g. Y for [Y/n]).
    # ESC or any other unrecognised key → decline (n if 'n' is valid,
    # otherwise fall back to default). Only an explicit valid key bypasses
    # the decline path — pressing 'w' must NOT accept a Y/n prompt.
    if [[ -z $key || $key == $'\n' || $key == $'\r' ]]; then
        key=$default
    else
        key=${key:l}
        if [[ $valid != *$key* ]]; then
            [[ $valid == *n* ]] && key=n || key=$default
        fi
    fi
    print -r -- "$key"
}

# _zdot_plugin_update_notice <lines…> — non-blocking mid-session presentation:
# render the summary and point at the apply command. NEVER reads the terminal.
# Used by the precmd when results arrive after the session's first prompt —
# i.e. potentially the instant the user returned from a fg application, which
# is exactly when a blocking single-key read would steal their leading ESC
# bytes and mangle their typing.
_zdot_plugin_update_notice() {
    emulate -L zsh
    setopt local_options
    _zdot_plugin_update_render_summary "$@"
    zdot_info "Run 'zdot plugin update' to apply." 2>/dev/null \
        || print -- "Run 'zdot plugin update' to apply."
}

_zdot_plugin_update_prompt_and_upgrade() {
    emulate -L zsh
    setopt local_options
    local -a lines=( "$@" )

    _zdot_plugin_update_render_summary "${lines[@]}"

    # Reminder mode: show the summary and stop. No prompt, no pull.
    if [[ "$(_zdot_plugin_update_mode)" == reminder ]]; then
        zdot_info "Run 'zdot plugin update' to apply." 2>/dev/null \
            || print -- "Run 'zdot plugin update' to apply."
        return 0
    fi

    local choice
    if _zdot_plugin_update_has_typed_input; then
        # User is mid-typing — render the prompt line as auto-dismissed
        # and treat as 'n'. Don't consume a pre-typed key as the answer.
        if _zdot_plugin_update_color_enabled; then
            print -P -- "  %F{cyan}Update all? [Y/n] ›%f n  %F{244}(skipped — typed input detected)%f"
        else
            print -- "  Update all? [Y/n] › n  (skipped — typed input detected)"
        fi
        choice=n
    else
        if _zdot_plugin_update_color_enabled; then
            print -nP -- "  %F{cyan}Update all? [Y/n] ›%f " >&2
        else
            print -n -- "  Update all? [Y/n] › " >&2
        fi
        choice=$(_zdot_plugin_update_read_key "yn" "y")
    fi

    case $choice in
        y) _zdot_plugin_update_run_all "${lines[@]}" ;;
        n) zdot_info "Skipped. Next check in $(_zdot_plugin_update_frequency)s." 2>/dev/null \
            || print -- "Skipped." ;;
    esac
}

# ============================================================================
# Apply: delegate to the existing CLI function.
# ============================================================================
# zdot_update_plugin (autoloaded from core/functions/) already handles
# bundle-aware dedupe, version pins, error reporting, and the summary
# line. We just hand it the list of bare specs the scan flagged.

_zdot_plugin_update_run_all() {
    emulate -L zsh
    setopt local_options
    local -a lines=( "$@" )
    local -a specs
    local line
    for line in "${lines[@]}"; do
        specs+=( ${${(s:	:)line}[1]} )
    done
    (( ${#specs} )) || return 0
    zdot_update_plugin "${specs[@]}"
}

# ============================================================================
# Background scan + precmd hook
# ============================================================================

# _zdot_plugin_update_precmd — fires before each prompt. While the scan is
# in flight it prints a one-shot faded "checking…" notice; once the pending
# file lands it consumes it, deregisters itself, and dispatches.
#
# first_call (from the _ANNOUNCED sentinel) gates the checking notice and
# leftover delivery. session_start is narrower: "the user has not run a
# command yet", the one moment a blocking [Y/n] is acceptable. Any later
# arrival may come the instant the user returns from a foreground app, when
# a single-key read would steal the leading ESC byte of their key sequences,
# so it gets a non-blocking notice instead.
_zdot_plugin_update_precmd() {
    emulate -L zsh
    setopt local_options

    local pending=$(_zdot_plugin_update_pending_path)

    # Defer one precmd under p10k instant-prompt so output doesn't corrupt
    # p10k's pre-prompt buffer. The first-call sentinel survives the deferral
    # so leftovers and our own results are still delivered on the next call.
    # That call follows the user's first command line, though, so it only
    # counts as session start if that line added no history event (a bare
    # Enter); _DEFERRED records $HISTCMD to tell.
    if (( ${+_ZDOT_PLUGIN_UPDATE_ANNOUNCED} && ! ${+_ZDOT_PLUGIN_UPDATE_P10K_DEFERRED} )) \
        && _zdot_plugin_update_p10k_active; then
        typeset -g _ZDOT_PLUGIN_UPDATE_P10K_DEFERRED=$HISTCMD
        return 0
    fi

    local first_call=0 session_start=0
    if (( ${+_ZDOT_PLUGIN_UPDATE_ANNOUNCED} )); then
        first_call=1
        if (( ! ${+_ZDOT_PLUGIN_UPDATE_P10K_DEFERRED} )) \
            || [[ $_ZDOT_PLUGIN_UPDATE_P10K_DEFERRED == "$HISTCMD" ]]; then
            session_start=1
        fi
        unset _ZDOT_PLUGIN_UPDATE_ANNOUNCED _ZDOT_PLUGIN_UPDATE_P10K_DEFERRED
    fi

    # Leftover pending files from shells that died before consuming their
    # scan: deliver as a non-blocking notice on the first call. Superseded
    # (dropped quietly) when this shell's own results already landed before
    # the prompt; hour-old leftovers were already deleted at spawn time.
    if (( first_call )) && (( ${+_ZDOT_PLUGIN_UPDATE_LEFTOVERS} )); then
        local leftover lcontent lfirst
        local -a lrows
        for leftover in "${_ZDOT_PLUGIN_UPDATE_LEFTOVERS[@]}"; do
            lcontent=$(<"$leftover") 2>/dev/null
            rm -f "$leftover" 2>/dev/null
            lfirst=${lcontent%%$'\n'*}
            if [[ $lfirst == ok || -z $lcontent ]]; then
                continue
            fi
            if [[ $lfirst == err ]]; then
                zdot_warn "plugin-update: leftover scan from a dead shell failed"
                continue
            fi
            lrows=( ${(f)lcontent} )
            lrows=( ${lrows:#} )
            [[ -e $pending ]] && continue
            (( ${#lrows} )) && _zdot_plugin_update_notice "${lrows[@]}"
        done
    fi
    unset _ZDOT_PLUGIN_UPDATE_LEFTOVERS

    if [[ ! -e $pending ]]; then
        if (( ! ${+_ZDOT_PLUGIN_UPDATE_SCAN_SPAWNED} )); then
            # Registered only to deliver leftovers; nothing more will
            # arrive, so stop paying for this hook on every prompt.
            precmd_functions=( ${precmd_functions:#_zdot_plugin_update_precmd} )
            return 0
        fi
        # Scan still running. One-shot faded "checking…" notice on the
        # first prompt, then wait silently.
        if (( first_call )); then
            zdot_info "%F{244}(checking for zdot plugin updates in the background…)%f"
        fi
        return 0
    fi

    # Pending result has landed — deregister so this hook stops firing.
    precmd_functions=( ${precmd_functions:#_zdot_plugin_update_precmd} )
    unset _ZDOT_PLUGIN_UPDATE_SCAN_SPAWNED

    local content
    content=$(<"$pending")
    rm -f "$pending"

    case ${content%%$'\n'*} in
        ok)
            zdot_info "%F{244}(no zdot plugin updates available)%f"
            ;;
        err)
            zdot_warn "plugin-update: background scan failed"
            ;;
        *)
            local -a outdated
            outdated=( ${(f)content} )
            outdated=( ${outdated:#} )
            (( ${#outdated} )) || return 0
            if (( session_start )); then
                # Results were waiting before the user ran anything: the
                # one moment a blocking [Y/n] is by design.
                _zdot_plugin_update_prompt_and_upgrade "${outdated[@]}"
            else
                # Mid-session arrival: never block; stdin untouched.
                _zdot_plugin_update_notice "${outdated[@]}"
            fi
            ;;
    esac
}

# _zdot_plugin_update_main — hook entry point. Forks a background
# subshell to run the scan; the subshell writes results atomically to the
# pending file. The parent registers a precmd hook to display them.
_zdot_plugin_update_main() {
    emulate -L zsh
    setopt local_options

    _zdot_plugin_update_should_run || return 0

    # Make sure the state dir exists before any state-file access. The
    # stamp file may legitimately not exist (fresh install — is_due treats
    # that as "due"), but acquire_lock and the bg subshell both write here.
    _zdot_plugin_update_ensure_state_dir

    # Pending is per-shell (pending.$$): scan results belong to the shell
    # that spawned them, so no other window's precmd can consume them there.
    # Files of other LIVE shells are theirs to consume; files of dead shells
    # are leftovers, adopted for a non-blocking first-prompt notice (or
    # deleted if hour-old). Registration is deduped (filter + append) since
    # the hook can be registered on this path even when a scan also spawns.
    #
    # This shell has only just started, so a pending.$$ already on disk was
    # written by a dead shell whose PID we reused (or by the shell this one
    # `exec`ed over). Left alone, the first precmd would present it as our
    # own fresh scan, and our real result would never be consumed.
    local pending=$(_zdot_plugin_update_pending_path)
    [[ -e $pending ]] && rm -f "$pending" 2>/dev/null
    local -a reply
    _zdot_plugin_update_pending_leftovers "$pending"
    typeset -ga _ZDOT_PLUGIN_UPDATE_LEFTOVERS
    _ZDOT_PLUGIN_UPDATE_LEFTOVERS=( "${reply[@]}" )

    if ! _zdot_plugin_update_is_due || ! _zdot_plugin_update_acquire_lock; then
        if (( ${#_ZDOT_PLUGIN_UPDATE_LEFTOVERS} )); then
            typeset -g _ZDOT_PLUGIN_UPDATE_ANNOUNCED=1
            precmd_functions=( ${precmd_functions:#_zdot_plugin_update_precmd} _zdot_plugin_update_precmd )
        fi
        return 0
    fi

    (
        local _pending=$(_zdot_plugin_update_pending_path)
        local _tmp="${_pending}.tmp"

        # Trap is the exit invariant: pending MUST exist by subshell exit
        # so the precmd has a reliable "done" signal. Happy-path writes it
        # plus a status=0 timestamp; the trap is the fallback for signal
        # interrupts and writes status=1 so the rate limit still applies
        # — we don't pound the network on every prompt while the user
        # repeatedly Ctrl-Cs the bg scan.
        #
        # zsh signal traps resume execution after they run, so INT/TERM
        # must `exit` explicitly; that in turn fires the EXIT trap. HUP is
        # ignored: if the terminal closes mid-scan, the scan finishes, and
        # its result becomes a leftover the next shell adopts.
        trap '_zdot_plugin_update_release_lock; [[ -e "$_pending" ]] || { print -r -- "err" > "$_pending"; _zdot_plugin_update_write_timestamp 1 "scan interrupted"; }; rm -f "$_tmp"' EXIT
        trap 'exit 1' INT TERM
        trap '' HUP

        local results
        results=$(_zdot_plugin_update_collect)
        if [[ -n $results ]]; then
            printf '%s' "$results" > "$_tmp"
        else
            print -r -- "ok" > "$_tmp"
        fi
        mv "$_tmp" "$_pending"

        _zdot_plugin_update_write_timestamp 0
        _zdot_plugin_update_release_lock
    ) 2>/dev/null &!

    typeset -g _ZDOT_PLUGIN_UPDATE_ANNOUNCED=1
    typeset -g _ZDOT_PLUGIN_UPDATE_SCAN_SPAWNED=1
    precmd_functions=( ${precmd_functions:#_zdot_plugin_update_precmd} _zdot_plugin_update_precmd )
}
