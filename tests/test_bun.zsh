#!/usr/bin/env zsh
# Harness: modules/bun — XDG dir resolution, legacy fallback, PATH wiring.
#
# Unit-level: sources modules/bun/bun.zsh with zdot_define_module and
# zdot_register_completion_file stubbed, then calls _bun_configure/_bun_load
# directly. Each case runs in its own `zsh -f` subshell with a throwaway HOME
# and a scrubbed bun environment, so nothing touches the real home.
#
# A fake `bun` executable stands in for the binary (only `-x` is checked).
#
# Run:  zsh -f tests/test_bun.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

if [[ "${1:-}" == --case ]]; then
    local sbx; sbx="$(mktemp -d "${TMPDIR:-/tmp}/zdot-bun-test.XXXXXX")"
    trap "rm -rf '$sbx'" EXIT
    export HOME="$sbx/home"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
    unset BUN_INSTALL BUN_INSTALL_BIN BUN_INSTALL_CACHE_DIR BUN_DNS_USE_IPV4
    mkdir -p "$HOME"
    path=(/usr/bin /bin)

    zdot_define_module() { : }
    _REGISTERED_COMPLETIONS=()
    zdot_register_completion_file() { _REGISTERED_COMPLETIONS+=("$1") }
    source "${ZDOT_ROOT}/modules/bun/bun.zsh" || { print "RESULT: FAIL (source)"; exit 2 }

    fail() { print -r -- "RESULT: FAIL ($*)"; exit 1 }
    eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'" }
    on_path() { (( ${path[(Ie)$1]} )) || fail "$1 not on PATH: $path" }
    off_path() { (( ! ${path[(Ie)$1]} )) || fail "$1 unexpectedly on PATH" }
    fake_bun() { mkdir -p "$1"; print '#!/bin/sh' > "$1/bun"; chmod +x "$1/bun" }
    fake_globals() { mkdir -p "$1/install/global"; print '{}' > "$1/install/global/package.json" }

    case "$2" in
        xdg-defaults)
            # Fresh machine: everything lands in XDG dirs.
            _bun_configure; _bun_load
            eq "$BUN_INSTALL" "$XDG_DATA_HOME/bun" BUN_INSTALL
            eq "$BUN_INSTALL_CACHE_DIR" "$XDG_CACHE_HOME/bun" BUN_INSTALL_CACHE_DIR
            eq "${BUN_INSTALL_BIN-unset}" unset BUN_INSTALL_BIN
            eq "$BUN_DNS_USE_IPV4" 1 BUN_DNS_USE_IPV4
            on_path "$XDG_DATA_HOME/bun/bin"
            eq "$path[-1]" "$XDG_DATA_HOME/bun/bin" "append position"
            eq "${_REGISTERED_COMPLETIONS[*]}" bun completions
            print "RESULT: PASS" ;;

        xdg-unset-falls-back-to-home)
            # XDG vars unset: same layout under ~/.local/share, ~/.cache.
            unset XDG_DATA_HOME XDG_CACHE_HOME
            _bun_configure
            eq "$BUN_INSTALL" "$HOME/.local/share/bun" BUN_INSTALL
            eq "$BUN_INSTALL_CACHE_DIR" "$HOME/.cache/bun" BUN_INSTALL_CACHE_DIR
            print "RESULT: PASS" ;;

        env-wins-over-xdg)
            # Variables already exported (e.g. by .zshenv) are left alone.
            export BUN_INSTALL="$HOME/custom" BUN_INSTALL_CACHE_DIR="$HOME/cc"
            _bun_configure
            eq "$BUN_INSTALL" "$HOME/custom" BUN_INSTALL
            eq "$BUN_INSTALL_CACHE_DIR" "$HOME/cc" BUN_INSTALL_CACHE_DIR
            print "RESULT: PASS" ;;

        zstyle-wins-over-env)
            export BUN_INSTALL="$HOME/env" BUN_INSTALL_CACHE_DIR="$HOME/envc"
            zstyle ':zdot:bun' install-dir "$HOME/zs"
            zstyle ':zdot:bun' cache-dir "$HOME/zsc"
            _bun_configure
            eq "$BUN_INSTALL" "$HOME/zs" BUN_INSTALL
            eq "$BUN_INSTALL_CACHE_DIR" "$HOME/zsc" BUN_INSTALL_CACHE_DIR
            print "RESULT: PASS" ;;

        xdg-no-leaves-bun-defaults)
            zstyle ':zdot:bun' xdg no
            _bun_configure; _bun_load
            eq "${BUN_INSTALL-unset}" unset BUN_INSTALL
            eq "${BUN_INSTALL_CACHE_DIR-unset}" unset BUN_INSTALL_CACHE_DIR
            # bun's own fallback when XDG_CACHE_HOME is set
            on_path "$XDG_CACHE_HOME/.bun/bin"
            print "RESULT: PASS" ;;

        legacy-home-bun-kept)
            # Existing ~/.bun with globals and no XDG dir: keep using it.
            fake_globals "$HOME/.bun"
            _bun_configure
            eq "$BUN_INSTALL" "$HOME/.bun" BUN_INSTALL
            eq "$BUN_INSTALL_CACHE_DIR" "$XDG_CACHE_HOME/bun" "cache still XDG"
            print "RESULT: PASS" ;;

        legacy-xdg-cache-bun-kept)
            # bun's own XDG_CACHE_HOME fallback dir, with globals.
            fake_globals "$XDG_CACHE_HOME/.bun"
            _bun_configure
            eq "$BUN_INSTALL" "$XDG_CACHE_HOME/.bun" BUN_INSTALL
            print "RESULT: PASS" ;;

        legacy-empty-dir-ignored)
            # `bun pm bin -g` alone creates an empty install/global: not legacy.
            mkdir -p "$HOME/.bun/install/global" "$HOME/.bun/bin"
            _bun_configure
            eq "$BUN_INSTALL" "$XDG_DATA_HOME/bun" BUN_INSTALL
            print "RESULT: PASS" ;;

        xdg-dir-beats-legacy)
            # Both exist (post-migration leftovers): XDG wins.
            fake_globals "$HOME/.bun"
            mkdir -p "$XDG_DATA_HOME/bun"
            _bun_configure
            eq "$BUN_INSTALL" "$XDG_DATA_HOME/bun" BUN_INSTALL
            print "RESULT: PASS" ;;

        curl-binary-on-path-in-configure)
            # Curl installer's binary must be on PATH after configure alone,
            # so the load hook's --requires-optional-tool gate can see it.
            fake_bun "$XDG_DATA_HOME/bun/bin"
            _bun_configure
            on_path "$XDG_DATA_HOME/bun/bin"
            [[ "$(whence -p bun)" == "$XDG_DATA_HOME/bun/bin/bun" ]] || fail "bun not resolvable"
            print "RESULT: PASS" ;;

        no-binary-not-on-path-in-configure)
            _bun_configure
            off_path "$XDG_DATA_HOME/bun/bin"
            print "RESULT: PASS" ;;

        global-bin-exported-and-on-path)
            zstyle ':zdot:bun' global-bin "$HOME/.local/bin"
            _bun_configure; _bun_load
            eq "$BUN_INSTALL_BIN" "$HOME/.local/bin" BUN_INSTALL_BIN
            on_path "$HOME/.local/bin"
            print "RESULT: PASS" ;;

        global-bin-and-curl-binary-both-on-path)
            zstyle ':zdot:bun' global-bin "$HOME/.local/bin"
            fake_bun "$XDG_DATA_HOME/bun/bin"
            _bun_configure; _bun_load
            on_path "$HOME/.local/bin"
            on_path "$XDG_DATA_HOME/bun/bin"
            print "RESULT: PASS" ;;

        prepend-position)
            zstyle ':zdot:bun' path-position prepend
            _bun_configure; _bun_load
            eq "$path[1]" "$XDG_DATA_HOME/bun/bin" "prepend position"
            print "RESULT: PASS" ;;

        no-duplicate-path)
            fake_bun "$XDG_DATA_HOME/bun/bin"
            _bun_configure; _bun_load; _bun_configure; _bun_load
            local bin_dir="$XDG_DATA_HOME/bun/bin"
            local -a hits=(${(M)path:#$bin_dir})
            eq "$#hits" 1 "PATH entries"
            print "RESULT: PASS" ;;

        dns-ipv4-off)
            zstyle ':zdot:bun' dns-ipv4 no
            _bun_configure
            eq "${BUN_DNS_USE_IPV4-unset}" unset BUN_DNS_USE_IPV4
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

local -a cases=(
    xdg-defaults xdg-unset-falls-back-to-home env-wins-over-xdg
    zstyle-wins-over-env xdg-no-leaves-bun-defaults legacy-home-bun-kept
    legacy-xdg-cache-bun-kept legacy-empty-dir-ignored xdg-dir-beats-legacy
    curl-binary-on-path-in-configure no-binary-not-on-path-in-configure
    global-bin-exported-and-on-path global-bin-and-curl-binary-both-on-path
    prepend-position no-duplicate-path dns-ipv4-off
)
local c out pass=0 failn=0
for c in $cases; do
    out="$(zsh -f "${ZDOT_ROOT}/tests/test_bun.zsh" --case "$c" 2>&1)"
    if [[ "$out" == *"RESULT: PASS"* ]]; then
        (( pass++ )); print -r -- "PASS  $c"
    else
        (( failn++ )); print -r -- "FAIL  $c"; print -r -- "      ${out//$'\n'/$'\n'      }"
    fi
done
print -r -- "--- $pass passed, $failn failed"
(( failn == 0 ))
