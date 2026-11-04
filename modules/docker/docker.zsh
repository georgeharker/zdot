#!/usr/bin/env zsh
# docker: client env (completions, plugin bin, DOCKER_HOST) + OrbStack shell
# integration. Engine-agnostic: works for orbstack/colima/parallels contexts.

_docker_init() {
    # Client config lives wherever DOCKER_CONFIG points (see
    # zdot-modules/env; XDG data dir). Never hardcode ~/.docker.
    local docker_config="${DOCKER_CONFIG:-${HOME}/.docker}"

    # .zshrc only loads this module on macOS, but guard defensively
    if [[ -d "$docker_config/" ]]; then
        [[ -d "$docker_config/bin" ]] && export PATH="${PATH}:$docker_config/bin"
        [[ -d "$docker_config/completions/" ]] \
            && zdot_add_fpath "$docker_config/completions" --glob '_*'
        # Derive DOCKER_HOST from the active context once per shell — keeps
        # non-shell consumers (SwiftBar, launchd apps) from having to.
        if command -v docker &>/dev/null && (( ! $+DOCKER_HOST )); then
            export DOCKER_HOST=`docker context ls --format json | jq -r 'select(.Current) | .DockerEndpoint'`
        fi
    fi

    # colima (default engine) — brew ships _colima into its site-functions,
    # normally already on fpath via the brew module; add only if missing.
    # (non-brew installs land completions elsewhere — this keeps them working.)
    if command -v colima &>/dev/null; then
        local colima_comp_dir="$(brew --prefix 2>/dev/null)/share/zsh/site-functions"
        if [[ -d "$colima_comp_dir" ]] && (( ${fpath[(Ie)$colima_comp_dir]} == 0 )); then
            zdot_add_fpath "$colima_comp_dir" --glob '_*'
        fi
    fi

    # OrbStack (optional engine) CLI tools + completions — owned here instead
    # of the block the app writes into ~/.zprofile (delete if it re-adds).
    # Resolve through the ~/.orbstack symlink (→ ~/.local/share/orbstack,
    # see install_orbstack); OrbStack rewrites these files on upgrades, so
    # never inline them.
    local orb_dir="${HOME}/.orbstack"
    if [[ -d "$orb_dir/shell" ]]; then
        [[ -d "$orb_dir/bin" ]] && export PATH="${PATH}:$orb_dir/bin"
        [[ -d "$orb_dir/shell/completions/zsh" ]] \
            && zdot_add_fpath "$orb_dir/shell/completions/zsh" --glob '_*'
    fi
}

zdot_simple_hook docker --provides docker-ready --group completions-producers
