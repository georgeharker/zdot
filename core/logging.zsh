#!/bin/zsh

# Global quiet mode setting - defaults to not quiet
# These can be overridden via zstyle before zdot.zsh is sourced:
#   zstyle ':zdot:logging' quiet   true
#   zstyle ':zdot:logging' verbose true
zdot_quiet_mode=false
zdot_verbose_mode=false
zstyle -t ':zdot:logging' quiet   && zdot_quiet_mode=true
zstyle -t ':zdot:logging' verbose && zdot_verbose_mode=true

# ---------------------------------------------------------------------------
# Deferred-execution logging state
#
# _ZDOT_DEFERRED_ACTIVE — set to 1 by hooks.zsh just before the first
#   zdot_defer call that kicks off deferred hook execution; reset to 0 when
#   the queue drains normally or a stall is detected.
#
# _ZDOT_DEFERRED_MESSAGES — accumulates every formatted log message that was
#   emitted while _ZDOT_DEFERRED_ACTIVE=1.  Replayed on the next ZLE redraw
#   and available afterwards via `zdot_show_deferred_log`.
# ---------------------------------------------------------------------------
typeset -gi _ZDOT_DEFERRED_ACTIVE=0
typeset -gi _ZDOT_DEFERRED_SHOWN=0
typeset -ga _ZDOT_DEFERRED_MESSAGES=()
typeset -g  _ZDOT_DEFERRED_CURRENT_HOOK=''

# ZLE fd-wakeup handler — registered via `zle -F fd _zdot_flush_handler` at
# each drain site in hooks.zsh.  /dev/null is always readable, so ZLE fires
# this on the very next idle tick — no keypress required.
#
# $1 is the fd that woke us; we must deregister and close it ourselves.
# After that we flush any accumulated deferred messages and redraw.
function _zdot_flush_handler() {
    local fd=$1
    # Deregister this handler and close the fd.
    zle -F $fd
    exec {fd}>&-
    # If messages are already shown (e.g. widget beat us), nothing to do.
    (( _ZDOT_DEFERRED_SHOWN )) && return 0
    _ZDOT_DEFERRED_SHOWN=1
    (( ${#_ZDOT_DEFERRED_MESSAGES} )) || return 0
    zle -I
    print -P "${(pj:\n:)_ZDOT_DEFERRED_MESSAGES}" >$TTY
    zle -R
}

# ZLE widget — fires on zle-line-pre-redraw.  Fallback path: handles the case
# where messages are already accumulated when ZLE first becomes active (e.g.
# if _zdot_flush_handler's fd fires before ZLE is fully initialised, or in
# environments where zle -F is not available).
function _zdot_deferred_progress_widget() {
    if (( _ZDOT_DEFERRED_ACTIVE )); then
        # Queue still running — progress display reserved for future feature.
        return 0
    elif (( ! _ZDOT_DEFERRED_SHOWN )); then
        # Queue drained — flush accumulated messages once.
        _ZDOT_DEFERRED_SHOWN=1
        (( ${#_ZDOT_DEFERRED_MESSAGES} )) || return 0
        zle -I
        print -P "${(pj:\n:)_ZDOT_DEFERRED_MESSAGES}" >$TTY
        zle -R
    else
        # Already flushed — deregister so this widget stops firing.
        add-zle-hook-widget -d zle-line-pre-redraw _zdot_deferred_progress_widget
    fi
}

# Register only in interactive shells with a terminal.
if [[ -o interactive && -t 1 ]]; then
    autoload -Uz add-zsh-hook add-zle-hook-widget
    zle -N _zdot_flush_handler
    zle -N _zdot_deferred_progress_widget
    add-zle-hook-widget zle-line-pre-redraw _zdot_deferred_progress_widget
fi

# Replay accumulated deferred messages to the terminal at any time.
function zdot_show_deferred_log() {
    if (( ! ${#_ZDOT_DEFERRED_MESSAGES} )); then
        print "No deferred messages."
        return 0
    fi
    print -P "${(pj:\n:)_ZDOT_DEFERRED_MESSAGES}"
}

function zdot_cleanup_logging(){
    # Unset variables
    unset zdot_quiet_mode 2>/dev/null
    unset zdot_verbose_mode 2>/dev/null
    unset _ZDOT_DEFERRED_ACTIVE 2>/dev/null
    unset _ZDOT_DEFERRED_SHOWN 2>/dev/null
    unset _ZDOT_DEFERRED_MESSAGES 2>/dev/null
    unset _ZDOT_DEFERRED_CURRENT_HOOK 2>/dev/null

    # Unset all functions defined in this file
    unset -f zdot_cleanup_logging 2>/dev/null
    unset -f zdot_info 2>/dev/null
    unset -f zdot_info_nonl 2>/dev/null
    unset -f zdot_success 2>/dev/null
    unset -f zdot_report 2>/dev/null
    unset -f zdot_action 2>/dev/null
    unset -f zdot_error 2>/dev/null
    unset -f zdot_warn 2>/dev/null
    unset -f zdot_show_deferred_log 2>/dev/null
    unset -f _zdot_flush_handler 2>/dev/null
    unset -f _zdot_deferred_progress_print 2>/dev/null
    unset -f _zdot_deferred_progress_widget 2>/dev/null
}

# Print the name of the currently-executing deferred hook to the terminal,
# if `zstyle ':zdot:defer' progress yes` is set.  This is live/ephemeral —
# it goes directly to $TTY and is NOT accumulated in _ZDOT_DEFERRED_MESSAGES.
function _zdot_deferred_progress_print() {
    zstyle -t ':zdot:defer' progress || return 0
    [[ -o zle && -n $TTY ]] || return 0
    print -Pn "\n%F{white}… ${(q)1}%f" >$TTY
}

# ---------------------------------------------------------------------------
# Internal helper: emit a formatted message.
#
# During deferred execution ($+zsh_defer_options is set by zsh-defer while a
# deferred command is running) we cannot print directly to the terminal — the
# output would appear mid-prompt.  Instead we:
#   1. Append the formatted message to _ZDOT_DEFERRED_MESSAGES.
#   2. Immediately call `zle -R` with all accumulated messages so the user
#      sees progress without waiting for the queue to drain.
#
# Outside of deferred execution the message is printed normally via print -P.
# ---------------------------------------------------------------------------
function _zdot_emit() {
    local msg="$1"
    if (( $+zsh_defer_options )); then
        # Accumulate the message; the ZLE widget (_zdot_deferred_progress_widget)
        # renders all accumulated messages on the next zle-line-pre-redraw event.
        _ZDOT_DEFERRED_MESSAGES+=("$msg")
    else
        print -P "$msg"
    fi
}

# Helper output functions that respect zdot_quiet_mode
function zdot_verbose(){
    [[ "$zdot_verbose_mode" = true ]] || return 0
    _zdot_emit "$*"
    return 0
}

function zdot_info(){
    [[ "$zdot_quiet_mode" = true ]] && return 0
    _zdot_emit "$*"
}

function zdot_info_nonl(){
    # In deferred context there is no meaningful "no-newline" — treat as a
    # regular line so the message is not silently dropped.
    [[ "$zdot_quiet_mode" = true ]] && return 0
    if (( $+zsh_defer_options )); then
        _zdot_emit "$*"
    else
        print -n -P "$*"
    fi
}

function zdot_success(){
    [[ "$zdot_quiet_mode" = true ]] && return 0
    _zdot_emit "%F{green}$*%f"
}

function zdot_report(){
    [[ "$zdot_quiet_mode" = true ]] && return 0
    _zdot_emit "%F{cyan}$*%f"
}

function zdot_action(){
    [[ "$zdot_quiet_mode" = true ]] && return 0
    _zdot_emit "%F{blue}$*%f"
}

function zdot_error(){
    [[ "$zdot_quiet_mode" = true ]] && return 0
    _zdot_emit "%F{red}$*%f"
}

function zdot_warn(){
    [[ "$zdot_quiet_mode" = true ]] && return 0
    _zdot_emit "%F{yellow}$*%f"
}
