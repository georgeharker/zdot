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
    unset BUN_INSTALL BUN_INSTALL_BIN BUN_INSTALL_CACHE_DIR BUN_DNS_USE_IPV4 XDG_CONFIG_HOME
    mkdir -p "$HOME"
    _real_bun="${commands[bun]:-}"
    path=(/usr/bin /bin)

    zdot_define_module() { : }
    _REGISTERED_COMPLETIONS=()
    zdot_register_completion_file() { _REGISTERED_COMPLETIONS+=("$1") }
    source "${ZDOT_ROOT}/modules/bun/bun.zsh" || { print "RESULT: FAIL (source)"; exit 2 }

    fail() { print -r -- "RESULT: FAIL ($*)"; exit 1 }
    eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'" }
    # bun prints realpaths (/private/var/... on macOS): compare resolved.
    _resolved_path() { local p; reply=(); for p in $path; do reply+=("${p:A}"); done }
    on_path() { _resolved_path; (( ${reply[(Ie)${1:A}]} )) || fail "$1 not on PATH: $path" }
    off_path() { _resolved_path; (( ! ${reply[(Ie)${1:A}]} )) || fail "$1 unexpectedly on PATH" }
    # The load hook asks the real bun. Put it first on PATH (via a private
    # dir, so its neighbours don't come along); skip if bun isn't installed.
    real_bun() {
        [[ -n "$_real_bun" ]] || { print "RESULT: SKIP (no bun)"; exit 0 }
        mkdir -p "$sbx/realbin"; ln -sf "$_real_bun" "$sbx/realbin/bun"
        path=("$sbx/realbin" $path); rehash
    }
    fake_bun() { mkdir -p "$1"; print '#!/bin/sh' > "$1/bun"; chmod +x "$1/bun" }
    fake_globals() { mkdir -p "$1/install/global"; print '{}' > "$1/install/global/package.json" }

    case "$2" in
        xdg-defaults)
            real_bun
            # Fresh machine: everything lands in XDG dirs.
            _bun_configure; _bun_load
            eq "$BUN_INSTALL" "$XDG_DATA_HOME/bun" BUN_INSTALL
            eq "$BUN_INSTALL_CACHE_DIR" "$XDG_CACHE_HOME/bun" BUN_INSTALL_CACHE_DIR
            eq "${BUN_INSTALL_BIN-unset}" unset BUN_INSTALL_BIN
            eq "$BUN_DNS_USE_IPV4" 1 BUN_DNS_USE_IPV4
            on_path "$XDG_DATA_HOME/bun/bin"
            eq "${path[-1]:A}" "${XDG_DATA_HOME:A}/bun/bin" "append position"
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
            real_bun
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
            real_bun
            zstyle ':zdot:bun' global-bin "$HOME/.local/bin"
            _bun_configure; _bun_load
            eq "$BUN_INSTALL_BIN" "$HOME/.local/bin" BUN_INSTALL_BIN
            on_path "$HOME/.local/bin"
            print "RESULT: PASS" ;;

        global-bin-and-curl-binary-both-on-path)
            real_bun
            zstyle ':zdot:bun' global-bin "$HOME/.local/bin"
            fake_bun "$XDG_DATA_HOME/bun/bin"
            _bun_configure; _bun_load
            on_path "$HOME/.local/bin"
            on_path "$XDG_DATA_HOME/bun/bin"
            print "RESULT: PASS" ;;

        prepend-position)
            real_bun
            zstyle ':zdot:bun' path-position prepend
            _bun_configure; _bun_load
            eq "${path[1]:A}" "${XDG_DATA_HOME:A}/bun/bin" "prepend position"
            print "RESULT: PASS" ;;

        no-duplicate-path)
            real_bun
            fake_bun "$XDG_DATA_HOME/bun/bin"
            _bun_configure; _bun_load; _bun_configure; _bun_load
            _resolved_path
            local -a hits=(${(M)reply:#${XDG_DATA_HOME:A}/bun/bin})
            eq "$#hits" 1 "PATH entries"
            print "RESULT: PASS" ;;

        dns-ipv4-off)
            zstyle ':zdot:bun' dns-ipv4 no
            _bun_configure
            eq "${BUN_DNS_USE_IPV4-unset}" unset BUN_DNS_USE_IPV4
            print "RESULT: PASS" ;;

        bunfig-xdg-global-bin)
            real_bun
            # $XDG_CONFIG_HOME/.bunfig.toml globalBinDir (with ~/) is on PATH
            # and NOT exported (bun reads the file itself).
            export XDG_CONFIG_HOME="$HOME/.config"; mkdir -p "$XDG_CONFIG_HOME"
            print -l '# global' '[install]' 'minimumReleaseAge = 432000' \
                'globalBinDir = "~/.local/bin"  # links here' > "$XDG_CONFIG_HOME/.bunfig.toml"
            _bun_configure; _bun_load
            on_path "$HOME/.local/bin"
            off_path "$XDG_DATA_HOME/bun/bin"
            eq "${BUN_INSTALL_BIN-unset}" unset BUN_INSTALL_BIN
            print "RESULT: PASS" ;;

        bunfig-xdg-hides-home)
            real_bun
            # XDG_CONFIG_HOME absolute: bun reads only the XDG file.
            export XDG_CONFIG_HOME="$HOME/.config"; mkdir -p "$XDG_CONFIG_HOME"
            print -l '[install]' "globalBinDir = '$HOME/fromhome'" > "$HOME/.bunfig.toml"
            _bun_configure; _bun_global_bin
            eq "${REPLY:A}" "${XDG_DATA_HOME:A}/bun/bin" "home bunfig ignored"
            print "RESULT: PASS" ;;

        bunfig-home-when-no-xdg-config)
            real_bun
            unset XDG_CONFIG_HOME
            print -l '[install]' "globalBinDir = '$HOME/fromhome'" > "$HOME/.bunfig.toml"
            _bun_configure; _bun_global_bin
            eq "${REPLY:A}" "${HOME:A}/fromhome" "home bunfig"
            print "RESULT: PASS" ;;

        bun-failure-adds-nothing)
            # bun on PATH but erroring: no bogus PATH entry, completions
            # still registered.
            mkdir -p "$sbx/badbin"; print -l '#!/bin/sh' 'exit 1' > "$sbx/badbin/bun"
            chmod +x "$sbx/badbin/bun"; path=("$sbx/badbin" $path); rehash
            local before="$path"
            _bun_configure; _bun_load
            eq "$path" "$before" "PATH unchanged"
            eq "${_REGISTERED_COMPLETIONS[*]}" bun completions
            print "RESULT: PASS" ;;

        env-bin-beats-bunfig)
            real_bun
            export XDG_CONFIG_HOME="$HOME/.config"; mkdir -p "$XDG_CONFIG_HOME"
            print -l '[install]' 'globalBinDir = "~/.local/bin"' > "$XDG_CONFIG_HOME/.bunfig.toml"
            export BUN_INSTALL_BIN="$HOME/envbin"
            _bun_configure; _bun_global_bin
            eq "${REPLY:A}" "${HOME:A}/envbin" "BUN_INSTALL_BIN wins"
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
    bunfig-xdg-global-bin bunfig-xdg-hides-home bunfig-home-when-no-xdg-config
    bun-failure-adds-nothing env-bin-beats-bunfig
)
local c out pass=0 failn=0
for c in $cases; do
    out="$(zsh -f "${ZDOT_ROOT}/tests/test_bun.zsh" --case "$c" 2>&1)"
    if [[ "$out" == *"RESULT: SKIP"* ]]; then
        print -r -- "SKIP  $c"
    elif [[ "$out" == *"RESULT: PASS"* ]]; then
        (( pass++ )); print -r -- "PASS  $c"
    else
        (( failn++ )); print -r -- "FAIL  $c"; print -r -- "      ${out//$'\n'/$'\n'      }"
    fi
done
print -r -- "--- $pass passed, $failn failed"
(( failn == 0 ))
