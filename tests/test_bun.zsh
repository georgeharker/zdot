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
    _real_node="${commands[node]:-}"
    path=(/usr/bin /bin)

    zdot_define_module() { : }
    _WARNINGS=()
    zdot_warn() { _WARNINGS+=("$*") }
    zdot_module_dir() { REPLY="${ZDOT_ROOT}/modules/bun" }
    zdot_interactive() { [[ -n "${TEST_INTERACTIVE:-}" ]] }
    # Real zstyle helpers from core/utils.zsh.
    eval "$(sed -n '/^zdot_zstyle_default()/,/^}/p;/^zdot_zstyle_get()/,/^}/p' "${ZDOT_ROOT}/core/utils.zsh")"
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
    SHIM_DIR="${ZDOT_ROOT}/modules/bun/shims"
    # A `#!/usr/bin/env node` script that reports which runtime ran it.
    probe() { mkdir -p "${1:h}"; print -l '#!/usr/bin/env node' \
        'console.log(typeof Bun !== "undefined" ? "bun" : "node")' > "$1"; chmod +x "$1" }
    # Run a command through the shim with only the given env (plus PATH).
    via_shim() {
        local nodedir="$1"; shift
        env -i HOME="$HOME" PATH="$SHIM_DIR:$nodedir:${_real_bun:h}:/usr/bin:/bin" \
            ${ZDOT_BUN_BUNNIFY:+ZDOT_BUN_BUNNIFY=$ZDOT_BUN_BUNNIFY} \
            ${ZDOT_BUN_BUNNIFY_TOOLS:+ZDOT_BUN_BUNNIFY_TOOLS=$ZDOT_BUN_BUNNIFY_TOOLS} \
            "$@" 2>&1
    }
    # A bun global install: <root>/install/global/{bun.lock,node_modules/<pkg>}
    # with a bin link <bin>/<name> -> the package's node-shebang script.
    fake_bun_tool() {   # <bun-install-root> <bin-dir> <name>
        local g="$1/install/global"
        mkdir -p "$g/node_modules/$3" "$2"; : > "$g/bun.lock"; print '{}' > "$g/package.json"
        probe "$g/node_modules/$3/cli.js"
        ln -sf "$g/node_modules/$3/cli.js" "$2/$3"
    }
    need_node_and_bun() {
        [[ -n "$_real_bun" && -n "$_real_node" ]] || { print "RESULT: SKIP (needs node and bun)"; exit 0 }
    }
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
            # Appended: global bin, then the module's helper dir after it.
            eq "${path[-2]:A}" "${XDG_DATA_HOME:A}/bun/bin" "append position"
            eq "${path[-1]}" "${ZDOT_ROOT}/modules/bun/bin" "helper dir last"
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
            eq "$path" "$before ${ZDOT_ROOT}/modules/bun/bin" "only the helper dir added"
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

        bunnify-explicit-by-default)
            real_bun
            _bun_configure; _bun_load
            off_path "$SHIM_DIR"
            eq "${ZDOT_BUN_BUNNIFY-unset}" unset ZDOT_BUN_BUNNIFY
            print "RESULT: PASS" ;;

        bunnify-opt-out-exports-and-goes-first)
            real_bun
            zstyle ':zdot:bun' bunnify opt-out
            zstyle ':zdot:bun' bunnify-exclude tsc prettierd
            _bun_configure; _bun_load
            eq "${path[1]}" "$SHIM_DIR" "shim dir first"
            eq "$ZDOT_BUN_BUNNIFY" opt-out ZDOT_BUN_BUNNIFY
            eq "$ZDOT_BUN_BUNNIFY_TOOLS" "tsc prettierd" ZDOT_BUN_BUNNIFY_TOOLS
            print "RESULT: PASS" ;;

        node-shim-ahead-of-nvm-at-load)
            # Noninteractive: nvm's eager `nvm use` already prepended its dir.
            real_bun
            path=("$HOME/.local/share/nvm/versions/node/v1/bin" $path)
            zstyle ':zdot:bun' bunnify opt-out
            _bun_configure; _bun_load
            eq "${path[1]}" "$SHIM_DIR" "shim ahead of nvm"
            print "RESULT: PASS" ;;

        node-shim-preexec-reasserts)
            # Interactive: a later `nvm use` prepends nvm; preexec moves the
            # shim back before the next command, once (no duplicates).
            real_bun
            TEST_INTERACTIVE=1
            zstyle ':zdot:bun' bunnify opt-out
            _bun_configure; _bun_load
            (( ${preexec_functions[(Ie)_bun_node_shim_first]} )) || fail "preexec hook not registered"
            path=("$HOME/nvm/bin" $path)
            local f; for f in $preexec_functions; do $f; done
            eq "${path[1]}" "$SHIM_DIR" "shim first after preexec"
            local -a hits=(${(M)path:#$SHIM_DIR})
            eq "$#hits" 1 "shim PATH entries"
            print "RESULT: PASS" ;;

        bunnify-explicit-cleans-up)
            real_bun
            zstyle ':zdot:bun' bunnify opt-out
            _bun_configure; _bun_load
            zstyle ':zdot:bun' bunnify explicit
            _bun_load
            off_path "$SHIM_DIR"
            eq "${ZDOT_BUN_BUNNIFY-unset}" unset ZDOT_BUN_BUNNIFY
            print "RESULT: PASS" ;;

        node-shim-routes-runtimes)
            # End to end through shims/node: scripts that resolve into a bun
            # global install run on bun unless excluded; anything else
            # (a bun-managed project's own bins, other node scripts, plain
            # node) on the real node.
            need_node_and_bun
            local bunroot="$sbx/bunhome" bindir="$sbx/bunhome/bin" nodedir="${_real_node:h}"
            fake_bun_tool "$bunroot" "$bindir" pi
            fake_bun_tool "$bunroot" "$bindir" tsc
            probe "$sbx/elsewhere/pi"
            # A bun project: bun.lock + node_modules/.bin, but not install/global.
            mkdir -p "$sbx/proj/node_modules/x" "$sbx/proj/node_modules/.bin"; : > "$sbx/proj/bun.lock"
            probe "$sbx/proj/node_modules/x/cli.js"
            ln -s ../x/cli.js "$sbx/proj/node_modules/.bin/x"
            export ZDOT_BUN_BUNNIFY=opt-out ZDOT_BUN_BUNNIFY_TOOLS="tsc"
            eq "$(via_shim $nodedir "$bindir/pi")" bun "bun global tool"
            eq "$(via_shim $nodedir "$bindir/tsc")" node "excluded tool"
            eq "$(via_shim $nodedir "$sbx/elsewhere/pi")" node "plain node script"
            eq "$(via_shim $nodedir "$sbx/proj/node_modules/.bin/x")" node "bun project's own bin"
            eq "$(via_shim $nodedir node -e 'console.log(typeof Bun)')" undefined "plain node -e"
            rm "$bunroot/install/global/bun.lock"
            eq "$(via_shim $nodedir "$bindir/pi")" node "no bun.lock: not a bun install"
            print "RESULT: PASS" ;;

        node-shim-no-real-node)
            need_node_and_bun
            local out; out="$(env -i HOME="$HOME" PATH="$SHIM_DIR:/usr/bin:/bin" "$SHIM_DIR/node" -v 2>&1)"
            eq "$?" 127 "exit status"
            [[ "$out" == *"no real node"* ]] || fail "message: $out"
            print "RESULT: PASS" ;;

        helper-bin-on-path)
            # bin/ (bun-as-npm) is appended whenever the module loads,
            # node-shim or not, and only once.
            real_bun
            _bun_configure; _bun_load; _bun_load
            local helper="${ZDOT_ROOT}/modules/bun/bin"
            on_path "$helper"
            local -a hits=(${(M)path:#$helper})
            eq "$#hits" 1 "helper PATH entries"
            [[ "$(whence -p bun-as-npm)" == "$helper/bun-as-npm" ]] || fail "bun-as-npm not resolvable"
            print "RESULT: PASS" ;;

        node-shim-skips-other-copies)
            # Two copies of the shim on PATH (e.g. live and dev zdot trees):
            # each must skip the other, not bounce between them.
            need_node_and_bun
            mkdir -p "$sbx/copy1" "$sbx/copy2"
            cp "$SHIM_DIR/node" "$sbx/copy1/node"; cp "$SHIM_DIR/node" "$sbx/copy2/node"
            local out
            out="$(env -i HOME="$HOME" PATH="$sbx/copy1:$sbx/copy2:${_real_node:h}:/usr/bin:/bin" \
                timeout 10 "$sbx/copy1/node" -e 'console.log("real")' 2>&1)"
            eq "$out" real "delegated past both copies"
            print "RESULT: PASS" ;;

        node-shim-symlinked-bin-dir)
            # Reached through symlinked dirs (bin dir and install root both
            # via links) still resolves into the global install -> bun.
            # `node -v` / `node -e` from inside the bin dir stay on node.
            need_node_and_bun
            local nodedir="${_real_node:h}"
            fake_bun_tool "$sbx/realroot" "$sbx/realbin" pi
            export ZDOT_BUN_BUNNIFY=opt-out
            ln -s "$sbx/realroot" "$sbx/rootlink"; ln -s "$sbx/realbin" "$sbx/binlink"
            eq "$(via_shim $nodedir "$sbx/binlink/pi")" bun "via symlinked bin dir"
            ln -s "$sbx/rootlink/install/global/node_modules/pi/cli.js" "$sbx/realbin/pi2"
            eq "$(via_shim $nodedir "$sbx/realbin/pi2")" bun "via symlinked install root"
            eq "$(cd "$sbx/realbin" && via_shim $nodedir node -e 'console.log(typeof Bun)')" undefined "node -e inside bin dir"
            eq "$(cd "$sbx/realbin" && via_shim $nodedir node -v | cut -c1)" v "node -v inside bin dir"
            print "RESULT: PASS" ;;

        node-shim-dedupes-both-forms)
            # A symlinked spelling of shims/ already on PATH (and the
            # resolved one) is removed when the shim moves to the front, and
            # both are removed when it's turned off.
            real_bun
            local alias_dir="$sbx/shims-link"; ln -s "$SHIM_DIR" "$alias_dir"
            _ZDOT_BUN_SHIM_DIR="$alias_dir"; _ZDOT_BUN_SHIM_DIR_REAL="${alias_dir:A}"
            path=("$HOME/nvm/bin" "${alias_dir:A}" $path "$alias_dir")
            zstyle ':zdot:bun' bunnify opt-out
            _bun_configure; _bun_load
            eq "${path[1]}" "$alias_dir" "shim first"
            local -a hits=(${(M)path:#($alias_dir|${alias_dir:A})})
            eq "$#hits" 1 "shim entries, either form"
            zstyle ':zdot:bun' bunnify explicit
            path+=("${alias_dir:A}")
            _bun_load
            hits=(${(M)path:#($alias_dir|${alias_dir:A})})
            eq "$#hits" 0 "removed in both forms when off"
            print "RESULT: PASS" ;;

        bunnify-explicit-ignores-lists)
            # Lists alone don't turn anything on: explicit is the default.
            real_bun
            zstyle ':zdot:bun' bunnify-include pi
            _bun_configure; _bun_load
            off_path "$SHIM_DIR"
            print "RESULT: PASS" ;;

        bunnify-opt-in-exports-include)
            real_bun
            zstyle ':zdot:bun' bunnify opt-in
            zstyle ':zdot:bun' bunnify-include pi copilot
            zstyle ':zdot:bun' bunnify-exclude tsc
            _bun_configure; _bun_load
            eq "${path[1]}" "$SHIM_DIR" "shim dir first"
            eq "$ZDOT_BUN_BUNNIFY" opt-in ZDOT_BUN_BUNNIFY
            eq "$ZDOT_BUN_BUNNIFY_TOOLS" "pi copilot" "include list, not exclude"
            print "RESULT: PASS" ;;

        bunnify-unknown-mode-warns)
            real_bun
            zstyle ':zdot:bun' bunnify always
            _bun_configure; _bun_load
            off_path "$SHIM_DIR"
            [[ "${_WARNINGS[*]}" == *"unknown bunnify mode 'always'"* ]] || fail "no warning: ${_WARNINGS[*]}"
            print "RESULT: PASS" ;;

        bunnify-explicit-removes-preexec)
            real_bun
            TEST_INTERACTIVE=1
            zstyle ':zdot:bun' bunnify opt-out
            _bun_configure; _bun_load
            zstyle ':zdot:bun' bunnify explicit
            _bun_load
            [[ -z ${(M)preexec_functions:#_bun_node_shim_first} ]] || fail "preexec hook still registered"
            print "RESULT: PASS" ;;

        bunnify-opt-in-routes)
            # opt-in: only listed tools on bun. Mode unset (a process that
            # inherited PATH but not the vars): nothing on bun.
            need_node_and_bun
            local bunroot="$sbx/bunhome" bindir="$sbx/bunhome/bin" nodedir="${_real_node:h}"
            fake_bun_tool "$bunroot" "$bindir" pi
            fake_bun_tool "$bunroot" "$bindir" tsc
            export ZDOT_BUN_BUNNIFY=opt-in ZDOT_BUN_BUNNIFY_TOOLS="pi"
            eq "$(via_shim $nodedir "$bindir/pi")" bun "included tool"
            eq "$(via_shim $nodedir "$bindir/tsc")" node "not included"
            unset ZDOT_BUN_BUNNIFY
            eq "$(via_shim $nodedir "$bindir/pi")" node "mode unset: nothing on bun"
            export ZDOT_BUN_BUNNIFY=sideways
            eq "$(via_shim $nodedir "$bindir/pi")" node "unknown mode: nothing on bun"
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
    bunnify-explicit-by-default bunnify-opt-out-exports-and-goes-first
    node-shim-ahead-of-nvm-at-load node-shim-preexec-reasserts
    bunnify-explicit-cleans-up node-shim-routes-runtimes node-shim-no-real-node
    helper-bin-on-path node-shim-skips-other-copies node-shim-symlinked-bin-dir
    node-shim-dedupes-both-forms
    bunnify-explicit-ignores-lists bunnify-opt-in-exports-include
    bunnify-unknown-mode-warns bunnify-explicit-removes-preexec bunnify-opt-in-routes
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
