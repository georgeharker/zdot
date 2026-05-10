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
#      "no plugin updates" line, logs an error, or pops the y/n prompt.
#   3. _zdot_plugin_update_prompt_and_upgrade renders the summary, gates on
#      _zdot_plugin_update_has_typed_input (auto-skips as 'n' if the user
#      is mid-typing), and on Y runs git pull --ff-only per plugin.

# ============================================================================
# State paths and config
# ============================================================================

_zdot_plugin_update_state_dir() {
    print -r -- "${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/plugin-update"
}
_zdot_plugin_update_pending_path() { print -r -- "$(_zdot_plugin_update_state_dir)/pending" }
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
# Skips silently:
#   - Bundles with no backing repo (zdot_plugin_repo returns 1).
#   - Pinned plugins (version set inline or via _ZDOT_PLUGINS_VERSION) —
#     the user explicitly chose that ref.
#   - Missing repos, non-git dirs, no upstream tracked, fetch failures.
_zdot_plugin_update_collect() {
    emulate -L zsh
    setopt local_options

    local -a specs=( "${_ZDOT_PLUGINS_ORDER[@]}" "${_ZDOT_BUNDLE_REPOS[@]}" )
    local -A seen
    local spec bare version repo_dir label current upstream

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
        [[ -z "$version" ]] || continue

        zdot_plugin_repo "$bare" 2>/dev/null || continue
        repo_dir=$REPLY
        zdot_plugin_name "$bare"
        label=$REPLY

        (( ${+seen[$repo_dir]} )) && continue
        # shuck: disable=C001
        seen[$repo_dir]=1

        [[ -d "$repo_dir/.git" ]] || continue

        (cd "$repo_dir" && command git fetch --quiet) 2>/dev/null
        current=$(cd "$repo_dir" && command git rev-parse --short HEAD 2>/dev/null)
        upstream=$(cd "$repo_dir" && command git rev-parse --short '@{u}' 2>/dev/null)
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
    local saved
    saved=$(stty -g 2>/dev/null) || return 1
    {
        stty -icanon
        zselect -t 0 -r 0
        return $?
    } always {
        stty "$saved"
    }
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
    local saved_tty
    if [[ -t 0 ]]; then
        saved_tty=$(stty -g 2>/dev/null)
        [[ -n $saved_tty ]] && stty -icanon echo min 1 time 0 2>/dev/null
        # shuck: disable=C008
        trap "[[ -n '$saved_tty' ]] && stty '$saved_tty' 2>/dev/null" EXIT
    fi
    if ! read -k 1 -u 0 key; then
        print -r -- "$default"; return
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
_zdot_plugin_update_precmd() {
    emulate -L zsh
    setopt local_options

    local pending=$(_zdot_plugin_update_pending_path)

    local first_call=0
    if (( ${+_ZDOT_PLUGIN_UPDATE_ANNOUNCED} )); then
        first_call=1
        unset _ZDOT_PLUGIN_UPDATE_ANNOUNCED
    fi

    if [[ ! -e $pending ]]; then
        if (( first_call )) && ! _zdot_plugin_update_p10k_active; then
            zdot_info "%F{244}(checking for zdot plugin updates in the background…)%f"
        fi
        return 0
    fi

    # Defer one precmd under p10k instant-prompt so output doesn't corrupt
    # p10k's pre-prompt buffer. We stay registered; the next precmd lands
    # after the real prompt is drawn and proceeds to consume.
    if (( first_call )) && _zdot_plugin_update_p10k_active; then
        return 0
    fi

    # Pending result has landed — deregister so this hook stops firing.
    precmd_functions=( ${precmd_functions:#_zdot_plugin_update_precmd} )

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
            (( ${#outdated} )) && _zdot_plugin_update_prompt_and_upgrade "${outdated[@]}"
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

    # If a previous shell's scan left orphaned results, register the hook
    # to display them even if our own rate limit isn't due.
    local pending=$(_zdot_plugin_update_pending_path)
    if [[ -e $pending ]]; then
        typeset -g _ZDOT_PLUGIN_UPDATE_ANNOUNCED=1
        precmd_functions+=(_zdot_plugin_update_precmd)
        return 0
    fi

    _zdot_plugin_update_is_due || return 0
    _zdot_plugin_update_acquire_lock || return 0

    (
        local _pending=$(_zdot_plugin_update_pending_path)
        local _tmp="${_pending}.tmp"

        # Trap is the exit invariant: pending MUST exist by subshell exit
        # so the precmd has a reliable "done" signal. Happy-path writes it
        # plus a status=0 timestamp; the trap is the fallback for signal
        # interrupts and writes status=1 so the rate limit still applies
        # — we don't pound the network on every prompt while the user
        # repeatedly Ctrl-Cs the bg scan.
        trap '_zdot_plugin_update_release_lock; [[ -e "$_pending" ]] || { print -r -- "err" > "$_pending"; _zdot_plugin_update_write_timestamp 1 "scan interrupted"; }; rm -f "$_tmp"' INT TERM EXIT

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
    precmd_functions+=(_zdot_plugin_update_precmd)
}
