#!/usr/bin/env zsh
# Harness: core/plugin-update.zsh — per-shell pending files, leftover
# adoption, the precmd's session-start vs mid-session presentation, the scan
# subshell's signal handling, and compare-then-restore tty changes.
#
# Each case runs in its own `zsh -f` subshell (no user rc, fresh globals)
# against a throwaway XDG_CACHE_HOME. tty cases run under a pseudo-terminal
# (zsh/zpty) so stty paths execute for real.
# Run:  zsh -f tests/test_plugin_update.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/core/plugin-update.zsh" || { print "RESULT: FAIL (cannot source)"; exit 2 }
    # Stubs for the zdot runtime the engine leans on.
    zdot_info() { print -r -- "INFO: $*" }
    zdot_warn() { print -r -- "WARN: $*" }
    zdot_interactive() { return 0 }
    zstyle ':zdot:plugin-update' mode prompt
    export NO_COLOR=1

    dir=$(_zdot_plugin_update_state_dir)
    mkdir -p $dir
    pending=$(_zdot_plugin_update_pending_path)
    row=$'zsh-users/zsh-autosuggestions\tzsh-autosuggestions\tabc1234\tdef5678'
    integer dead_pid=99000
    while kill -0 $dead_pid 2>/dev/null; do (( dead_pid++ )); done
    hooked() { (( ${precmd_functions[(I)_zdot_plugin_update_precmd]} )) }
    not_due() { _zdot_plugin_update_write_timestamp 0 }
    pass() { print "RESULT: PASS"; exit 0 }
    fail() { print "RESULT: FAIL ($*)"; exit 1 }

    case "$2" in
        live-owner-not-adopted)
            sleep 30 &
            live=$!
            print -r -- $row > $dir/pending.$live
            touch -t 202001010000 $dir/pending.$live
            not_due
            _zdot_plugin_update_main
            kill $live
            (( ${#_ZDOT_PLUGIN_UPDATE_LEFTOVERS} == 0 )) || fail "live file adopted"
            [[ -e $dir/pending.$live ]] || fail "live file deleted"
            hooked && fail "hook registered for nothing"
            pass ;;
        dead-hour-old-deleted)
            print -r -- $row > $dir/pending.$dead_pid
            touch -t 202001010000 $dir/pending.$dead_pid
            not_due
            _zdot_plugin_update_main
            [[ -e $dir/pending.$dead_pid ]] && fail "stale file kept"
            (( ${#_ZDOT_PLUGIN_UPDATE_LEFTOVERS} == 0 )) || fail "stale file adopted"
            pass ;;
        leftover-notice-then-deregister)
            print -r -- $row > $dir/pending.$dead_pid
            not_due
            _zdot_plugin_update_main
            hooked || fail "hook not registered"
            out=$({ _zdot_plugin_update_precmd; hooked && print HOOKED } 2>&1)
            [[ $out == *zsh-autosuggestions* ]] || fail "notice missing: $out"
            [[ $out == *"Update all"* ]] && fail "blocking prompt shown"
            [[ $out == *HOOKED* ]] && fail "hook not deregistered"
            [[ -e $dir/pending.$dead_pid ]] && fail "leftover not consumed"
            pass ;;
        leftover-survives-p10k-deferral)
            POWERLEVEL9K_INSTANT_PROMPT=quiet
            print -r -- $row > $dir/pending.$dead_pid
            not_due
            _zdot_plugin_update_main
            # Not $(...): the deferral state must persist in this shell.
            _zdot_plugin_update_precmd > $dir/first.out
            first=$(<$dir/first.out)
            [[ -z $first ]] || fail "printed during instant prompt: $first"
            _zdot_plugin_update_precmd > $dir/second.out
            second=$(<$dir/second.out)
            [[ $second == *zsh-autosuggestions* ]] || fail "leftover lost: $second"
            hooked && fail "hook not deregistered"
            pass ;;
        own-pid-stale-discarded)
            print -r -- $row > $pending
            not_due
            _zdot_plugin_update_main
            [[ -e $pending ]] && fail "stale own-PID file kept"
            (( ${+_ZDOT_PLUGIN_UPDATE_ANNOUNCED} )) && fail "announced for a stale file"
            pass ;;
        session-start-prompts)
            print -r -- $row > $pending
            typeset -g _ZDOT_PLUGIN_UPDATE_ANNOUNCED=1
            out=$(_zdot_plugin_update_precmd <<< n 2>&1)
            [[ $out == *"Update all"* ]] || fail "no prompt at session start: $out"
            pass ;;
        p10k-after-command-is-notice)
            POWERLEVEL9K_INSTANT_PROMPT=quiet
            print -r -- $row > $pending
            typeset -g _ZDOT_PLUGIN_UPDATE_ANNOUNCED=1
            typeset -g _ZDOT_PLUGIN_UPDATE_P10K_DEFERRED=$(( HISTCMD - 1 ))
            out=$(_zdot_plugin_update_precmd 2>&1)
            [[ $out == *zsh-autosuggestions* ]] || fail "notice missing: $out"
            [[ $out == *"Update all"* ]] && fail "blocking prompt after a command"
            pass ;;
        mid-session-is-notice)
            print -r -- $row > $pending
            out=$(_zdot_plugin_update_precmd 2>&1)
            [[ $out == *zsh-autosuggestions* ]] || fail "notice missing: $out"
            [[ $out == *"Update all"* ]] && fail "blocking prompt mid-session"
            pass ;;
        scan-exits-on-term)
            _zdot_plugin_update_collect() {
                zmodload zsh/system
                print -r -- $sysparams[ppid] > $dir/scan.pid
                sleep 3
                print -r -- $row
            }
            _zdot_plugin_update_main
            integer i=0
            while [[ ! -s $dir/scan.pid ]] && (( i++ < 50 )); do sleep 0.1; done
            scan=$(<$dir/scan.pid)
            kill -TERM $scan
            i=0
            while [[ ! -e $pending ]] && (( i++ < 50 )); do sleep 0.1; done
            [[ $(<$pending) == err ]] || fail "pending not err: $(<$pending)"
            i=0
            while kill -0 $scan 2>/dev/null && (( i++ < 20 )); do sleep 0.1; done
            kill -0 $scan 2>/dev/null && fail "scan kept running after TERM"
            [[ -d $(_zdot_plugin_update_lock_path) ]] && fail "lock not released"
            pass ;;
        tty-*)
            zmodload zsh/zpty
            cat > $dir/pty.zsh <<EOF
source '${ZDOT_ROOT}/core/plugin-update.zsh'
tty_flag() {
    local cur=" \${\$(stty -a)//[;\$'\\n'\$'\\t']/ } "
    [[ \$cur == *" \$1 "* ]] && print on || print off
}
case $2 in
    tty-undo-list)
        stty echo icanon
        _zdot_plugin_update_tty_apply -icanon echo
        print -r -- "undo=[\${\${(@ps:\\t:)REPLY}[3]}]"
        _zdot_plugin_update_tty_undo "\$REPLY" ;;
    tty-concurrent-change)
        stty echo icanon ixon
        _zdot_plugin_update_tty_apply -echo -icanon
        tok=\$REPLY
        stty -ixon
        _zdot_plugin_update_tty_undo "\$tok"
        print -r -- "after: echo=\$(tty_flag echo) icanon=\$(tty_flag icanon) ixon=\$(tty_flag ixon)" ;;
    tty-typed-input)
        stty -echo icanon
        _zdot_plugin_update_has_typed_input
        print -r -- "after: echo=\$(tty_flag echo) icanon=\$(tty_flag icanon)" ;;
esac
print -r -- PTY_DONE
EOF
            zpty _t "zsh -f $dir/pty.zsh"
            out=
            line=
            while zpty -r _t line; do
                out+=$line
                [[ $line == *PTY_DONE* ]] && break
            done
            zpty -d _t
            out=${out//$'\r'/}
            case $2 in
                tty-undo-list)
                    [[ $out == *"undo=[icanon]"* ]] || fail "undo list: $out" ;;
                tty-concurrent-change)
                    [[ $out == *"after: echo=on icanon=on ixon=off"* ]] || fail "$out" ;;
                tty-typed-input)
                    [[ $out == *"after: echo=off icanon=on"* ]] || fail "$out" ;;
            esac
            pass ;;
        *) fail "unknown case $2" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
integer pass=0 fail=0
local c out tmp nl=$'\n'
for c in \
    live-owner-not-adopted dead-hour-old-deleted leftover-notice-then-deregister \
    leftover-survives-p10k-deferral own-pid-stale-discarded session-start-prompts \
    p10k-after-command-is-notice mid-session-is-notice scan-exits-on-term \
    tty-undo-list tty-concurrent-change tty-typed-input
do
    tmp=$(mktemp -d)
    out=$(env -i HOME=$tmp PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm \
        XDG_CACHE_HOME=$tmp/cache zsh -f "${(%):-%x}" --case "$c" 2>&1)
    if [[ $out == *"RESULT: PASS"* ]]; then
        (( pass++ ))
    else
        (( fail++ ))
        print -r -- "FAIL  $c"
        print -r -- "      ${out//$nl/$nl      }"
    fi
    rm -rf -- $tmp
done
print -r -- "plugin-update: $pass passed, $fail failed"
(( fail == 0 ))
