#!/usr/bin/env zsh
# Harness: modules/nodejs — providers (nvm, nvm-lazy, system), nvm's current
# link, the lazy `nvm`, which plugins load.
#
# Unit-level: sources modules/nodejs/nodejs.zsh with zdot's API stubbed and
# calls _node_configure directly. Each case runs in its own `zsh -f` with a
# throwaway HOME holding a FAKE nvm: nvm.sh defines an `nvm` function that
# logs every call to $NVM_DIR/calls and, for `nvm use`, writes the current
# link the way NVM_SYMLINK_CURRENT=true makes real nvm do. No real nvm, node
# or network is touched.
#
# Run:  zsh -f tests/test_nodejs.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    local sbx; sbx="$(mktemp -d "${TMPDIR:-/tmp}/zdot-node-test.XXXXXX")"
    trap "rm -rf '$sbx'" EXIT
    export HOME="$sbx/home" XDG_DATA_HOME="$sbx/home/.local/share"
    unset NVM_DIR NVM_SYMLINK_CURRENT
    mkdir -p "$HOME"
    path=(/usr/bin /bin)

    zdot_define_module() { : }
    zdot_is_newer_or_missing() { return 1 }   # skip zcompile of the fake
    zdot_use_plugin() { : }
    _COMPILE_EXTRA=(); zdot_plugin_compile_extra() { _COMPILE_EXTRA+=("$*") }
    _LIVE=(); zdot_register_completion_live() { _LIVE+=("$1") }
    _LOADED=(); zdot_load_plugin() { _LOADED+=("$1") }
    _DEFERRED=(); zdot_defer_until() { _DEFERRED+=("$*") }
    zdot_interactive() { [[ -n "${TEST_INTERACTIVE:-}" ]] }
    _WARNINGS=()
    zdot_warn() { _WARNINGS+=("$*") }
    eval "$(sed -n '/^zdot_zstyle_default()/,/^}/p;/^zdot_zstyle_get()/,/^}/p' "${ZDOT_ROOT}/core/utils.zsh")"
    source "${ZDOT_ROOT}/modules/nodejs/nodejs.zsh" || { print "RESULT: FAIL (source)"; exit 2 }

    fail() { print -r -- "RESULT: FAIL ($*)"; exit 1 }
    eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'" }

    nvm_dir="$XDG_DATA_HOME/nvm"
    calls() { [[ -f "$nvm_dir/calls" ]] && cat "$nvm_dir/calls" }
    # fake_nvm [default-version] — nvm.sh plus installed versions.
    fake_nvm() {
        local v="${1:-v9.9.9}"
        mkdir -p "$nvm_dir/alias"
        print -r -- "$v" > "$nvm_dir/alias/default"
        cat > "$nvm_dir/nvm.sh" <<'EOF'
print -r -- "sourced $*" >> "$NVM_DIR/calls"
nvm() {
    print -r -- "nvm $*" >> "$NVM_DIR/calls"
    if [[ "$1" == use ]]; then
        local v; v="$(<"$NVM_DIR/alias/default")"
        local d="$NVM_DIR/versions/node/$v"
        [[ -x "$d/bin/node" ]] || return 3
        [[ "${NVM_SYMLINK_CURRENT-}" == true ]] && ln -sfn "$d" "$NVM_DIR/current"
    fi
    return 0
}
EOF
    }
    fake_version() {
        mkdir -p "$nvm_dir/versions/node/$1/bin"
        print '#!/bin/sh' > "$nvm_dir/versions/node/$1/bin/node"
        chmod +x "$nvm_dir/versions/node/$1/bin/node"
    }

    case "$2" in
        nvm-default-creates-link)
            # Default provider, no link yet: nvm runs once (in a subshell) to
            # write it; current/bin goes first on PATH.
            fake_nvm v9.9.9; fake_version v9.9.9
            _node_configure
            eq "$NVM_SYMLINK_CURRENT" true NVM_SYMLINK_CURRENT
            eq "$(readlink "$nvm_dir/current")" "$nvm_dir/versions/node/v9.9.9" "current link"
            eq "${path[1]}" "$nvm_dir/current/bin" "current/bin first"
            [[ "$(calls)" == *"sourced --no-use"*"nvm use default --silent"* ]] || fail "nvm not run once: $(calls)"
            # nvm's functions stayed in the subshell; `nvm` here is the lazy stub.
            [[ "${functions[nvm]}" == *_nvm_lazy_load* ]] || fail "nvm isn't the lazy stub"
            print "RESULT: PASS" ;;

        nvm-valid-link-runs-no-nvm)
            fake_nvm; fake_version v9.9.9
            ln -s "$nvm_dir/versions/node/v9.9.9" "$nvm_dir/current"
            _node_configure
            eq "${path[1]}" "$nvm_dir/current/bin" "current/bin first"
            eq "$(calls)" "" "nvm calls"
            print "RESULT: PASS" ;;

        nvm-dangling-link-repaired)
            # The linked version was uninstalled: recreate from the default.
            fake_nvm v9.9.9; fake_version v9.9.9
            ln -s "$nvm_dir/versions/node/v1.0.0" "$nvm_dir/current"
            _node_configure
            eq "$(readlink "$nvm_dir/current")" "$nvm_dir/versions/node/v9.9.9" "current link"
            eq "${path[1]}" "$nvm_dir/current/bin" "current/bin first"
            print "RESULT: PASS" ;;

        nvm-link-cant-be-made)
            # Default points at nothing installed: PATH untouched, no error.
            fake_nvm v9.9.9
            local before="$path"
            _node_configure
            eq "$path" "$before" "PATH unchanged"
            [[ "${functions[nvm]}" == *_nvm_lazy_load* ]] || fail "nvm isn't the lazy stub"
            print "RESULT: PASS" ;;

        nvm-idempotent)
            fake_nvm; fake_version v9.9.9
            ln -s "$nvm_dir/versions/node/v9.9.9" "$nvm_dir/current"
            _node_configure; _node_configure
            local -a hits=(${(M)path:#$nvm_dir/current/bin})
            eq "$#hits" 1 "current/bin entries"
            print "RESULT: PASS" ;;

        system-leaves-path)
            fake_nvm; fake_version v9.9.9
            zstyle ':zdot:nodejs' provider system
            local before="$path"
            _node_configure
            eq "$path" "$before" "PATH unchanged"
            eq "${NVM_SYMLINK_CURRENT-unset}" unset NVM_SYMLINK_CURRENT
            [[ ! -e "$nvm_dir/current" ]] || fail "current link created"
            eq "$(calls)" "" "nvm calls"
            [[ "${functions[nvm]}" == *_nvm_lazy_load* ]] || fail "nvm isn't the lazy stub"
            print "RESULT: PASS" ;;

        no-nvm-installed)
            # Either provider: nothing nvm-related beyond NVM_DIR.
            local before="$path"
            _node_configure
            eq "$NVM_DIR" "$nvm_dir" NVM_DIR
            eq "$path" "$before" "PATH unchanged"
            (( ! ${+functions[nvm]} )) || fail "nvm defined without nvm installed"
            print "RESULT: PASS" ;;

        unknown-provider-warns)
            fake_nvm; fake_version v9.9.9
            zstyle ':zdot:nodejs' provider fnm
            local before="$path"
            _node_configure
            eq "$path" "$before" "PATH unchanged (system)"
            [[ "${_WARNINGS[*]}" == *"unknown provider 'fnm'"* ]] || fail "no warning: ${_WARNINGS[*]}"
            print "RESULT: PASS" ;;

        lazy-nvm-loads-once)
            # First `nvm` call sources nvm.sh with --no-use and runs the real
            # one; later calls go straight to it.
            fake_nvm; fake_version v9.9.9
            zstyle ':zdot:nodejs' provider system
            _node_configure
            nvm ls >/dev/null; nvm current >/dev/null
            eq "$(calls)" $'sourced --no-use\nnvm ls\nnvm current' "nvm calls"
            [[ "${functions[nvm]}" != *_nvm_lazy_load* ]] || fail "still the lazy stub"
            print "RESULT: PASS" ;;

        load-default-skips-omz-nvm)
            # Default provider: only the npm plugin loads; the OMZ nvm
            # plugin (and its eval) never runs. Same for system.
            fake_nvm; fake_version v9.9.9
            _node_configure; _node_load
            eq "${_LOADED[*]}" "omz:plugins/npm" "plugins loaded (nvm)"
            _LOADED=(); zstyle ':zdot:nodejs' provider system
            _node_configure; _node_load
            eq "${_LOADED[*]}" "omz:plugins/npm" "plugins loaded (system)"
            print "RESULT: PASS" ;;

        init-hooks-noop-unless-nvm-lazy)
            fake_nvm; fake_version v9.9.9
            ln -s "$nvm_dir/versions/node/v9.9.9" "$nvm_dir/current"
            TEST_INTERACTIVE=1
            _node_configure
            _nvm_interactive_init; _nvm_noninteractive_init
            eq "${_DEFERRED[*]}" "" "deferred calls"
            eq "$(calls)" "" "nvm calls"
            print "RESULT: PASS" ;;

        nvm-lazy-interactive)
            # Classic: OMZ plugin with lazy stubs + lazy-cmd, deferred
            # `nvm use node`; no symlink setup, no own nvm stub.
            fake_nvm; fake_version v9.9.9
            TEST_INTERACTIVE=1
            zstyle ':zdot:nodejs' provider nvm-lazy
            zstyle ':zdot:nodejs' lazy-cmd nx
            local before="$path"
            _node_configure; _node_load
            eq "$(zstyle -L ':omz:plugins:nvm' lazy)" "zstyle :omz:plugins:nvm lazy yes" "lazy style"
            eq "$(zstyle -L ':omz:plugins:nvm' lazy-cmd)" "zstyle :omz:plugins:nvm lazy-cmd nx" "lazy-cmd style"
            eq "${_LOADED[*]}" "omz:plugins/npm omz:plugins/nvm" "plugins loaded"
            eq "$path" "$before" "PATH unchanged"
            eq "${NVM_SYMLINK_CURRENT-unset}" unset NVM_SYMLINK_CURRENT
            (( ! ${+functions[nvm]} )) || fail "own nvm stub defined"
            functions[nvm]=': plugin stub'   # what the OMZ plugin would define
            _nvm_interactive_init
            eq "${_DEFERRED[*]}" "-q 1 nvm use node --silent" "deferred nvm use"
            print "RESULT: PASS" ;;

        nvm-lazy-noninteractive)
            # Noninteractive (and $NVIM): eager load, immediate `nvm use node`.
            fake_nvm; fake_version v9.9.9
            zstyle ':zdot:nodejs' provider nvm-lazy
            _node_configure
            eq "$(zstyle -L ':omz:plugins:nvm' lazy)" "zstyle :omz:plugins:nvm lazy no" "lazy style"
            source "$nvm_dir/nvm.sh"   # what the plugin does with lazy no
            _nvm_noninteractive_init
            [[ "$(calls)" == *"nvm use node --silent"* ]] || fail "no nvm use: $(calls)"
            TEST_INTERACTIVE=1 NVIM=/tmp/nvim.sock _node_configure
            eq "$(zstyle -L ':omz:plugins:nvm' lazy)" "zstyle :omz:plugins:nvm lazy no" "lazy style under NVIM"
            print "RESULT: PASS" ;;

        nvm-sh-on-compile-list)
            fake_nvm; fake_version v9.9.9
            _node_configure
            eq "${_COMPILE_EXTRA[*]}" "omz:plugins/npm $nvm_dir/nvm.sh" "compile extra"
            print "RESULT: PASS" ;;

        completion-registered-and-gated)
            # Registered at source time; sources nvm's bash completion for
            # nvm/system, skips nvm-lazy (the OMZ plugin does it there).
            fake_nvm; fake_version v9.9.9
            ln -s "$nvm_dir/versions/node/v9.9.9" "$nvm_dir/current"
            eq "${_LIVE[*]}" _nvm_completion "live completion registered"
            # Fake script: records whether compinit was already defined
            # (nvm's own test), so we can check it would skip running it.
            print -l 'command -v compinit >/dev/null && c=declared || c=missing' \
                'print -r -- "completion-sourced compinit=$c" >> "$NVM_DIR/calls"' > "$nvm_dir/bash_completion"
            _node_configure; _nvm_completion
            eq "$(calls)" "completion-sourced compinit=declared" "nvm provider"
            : > "$nvm_dir/calls"
            zstyle ':zdot:nodejs' provider nvm-lazy
            _node_configure; _nvm_completion
            eq "$(calls)" "" "nvm-lazy skips"
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

local -a cases=(
    nvm-default-creates-link nvm-valid-link-runs-no-nvm nvm-dangling-link-repaired
    nvm-link-cant-be-made nvm-idempotent system-leaves-path no-nvm-installed
    unknown-provider-warns lazy-nvm-loads-once
    load-default-skips-omz-nvm init-hooks-noop-unless-nvm-lazy
    nvm-lazy-interactive nvm-lazy-noninteractive
    nvm-sh-on-compile-list completion-registered-and-gated
)
local c out pass=0 failn=0
for c in $cases; do
    out="$(zsh -f "${ZDOT_ROOT}/tests/test_nodejs.zsh" --case "$c" 2>&1)"
    if [[ "$out" == *"RESULT: PASS"* ]]; then
        (( pass++ )); print -r -- "PASS  $c"
    else
        (( failn++ )); print -r -- "FAIL  $c"; print -r -- "      ${out//$'\n'/$'\n'      }"
    fi
done
print -r -- "--- $pass passed, $failn failed"
(( failn == 0 ))
