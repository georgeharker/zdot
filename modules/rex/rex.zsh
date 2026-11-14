#!/usr/bin/env zsh
# rex: Rex terminal CLI on PATH + zsh completions (macOS only)
#
# The `rex` CLI does not live in the /Applications bundle: it ships inside the
# Rex Server bundle under Application Support. Rex puts that directory on PATH
# (and sets REX_BIN_DIR) only for shells IT spawns — so in any other terminal,
# tmux, ssh-in, or a launchd-run script, `rex` is missing. This module makes it
# available everywhere, gated on the app actually being installed.
#
# zstyle (all optional):
#   zstyle ':zdot:rex' app     <path...>   app bundles that count as "installed"
#                                          (default: /Applications/Rex.app
#                                           "/Applications/Rex Beta.app")
#   zstyle ':zdot:rex' bin-dir <path>      dir containing the `rex` binary
#                                          (default: $REX_BIN_DIR, else the
#                                           RexServer Versions/Current bundle)

_rex_init() {
    zdot_is_macos || return 0

    # Installed? Any configured app bundle present.
    local -a apps
    zstyle -a ':zdot:rex' app apps \
        || apps=(/Applications/Rex.app "/Applications/Rex Beta.app")
    local app installed=0
    for app in "${apps[@]}"; do
        [[ -d "$app" ]] && { installed=1; break }
    done
    (( installed )) || return 0

    # PATH: only if rex doesn't already resolve (e.g. inside a Rex-spawned
    # shell, whose PATH carries the versioned bundle dir) — don't add a second
    # copy. Not an early return: completions below apply either way.
    if (( ! $+commands[rex] )); then
        local bin_dir
        zstyle -s ':zdot:rex' bin-dir bin_dir \
            || bin_dir="${REX_BIN_DIR:-${HOME}/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS}"
        [[ -x "$bin_dir/rex" ]] && (( ! ${path[(Ie)$bin_dir]} )) && path+=("$bin_dir")
    fi

    # Generated into the zdot completions dir by refresh_completions; skipped
    # if rex still isn't on PATH, regenerated when the binary is newer.
    zdot_register_completion_file "rex" "rex completion zsh"
}

# --provides-tool rex: _rex_init is what puts rex on PATH, so consumers using
# --requires-optional-tool rex order after it (and are gate-skipped if absent).
# --group completions-producers: _rex_init registers completions in its body
# (and puts rex on PATH for the gen command), so completions finalization must
# wait for it (see modules/completions).
zdot_simple_hook rex \
    --requires-group rex-configure \
    --provides-tool rex \
    --group completions-producers
