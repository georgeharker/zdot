#!/usr/bin/env zsh
# docker: Docker completions manager environment

_docker_init() {
    # Honor DOCKER_CONFIG if set (see zdot-modules/env), else fall back to the
    # legacy ~/.docker. Never hardcode ~/.docker when the user relocated it.
    local docker_config="${DOCKER_CONFIG:-${HOME}/.docker}"

    # .zshrc only loads this module on macOS, but guard defensively
    if [[ -d "$docker_config/" ]]; then
        if [[ -d "$docker_config/bin" ]]; then
            export PATH="${PATH}:$docker_config/bin"
        fi
        if [[ -d "$docker_config/completions/" ]]; then
            zdot_add_fpath "$docker_config/completions" --glob '_*'
        fi
        if command -v docker &>/dev/null; then
            if (( ! $+DOCKER_HOST )); then
                export DOCKER_HOST=`docker context ls --format json | jq -r 'select(.Current) | .DockerEndpoint'`
            fi
        fi
    fi
}

zdot_simple_hook docker --provides docker-ready --group completions-producers
