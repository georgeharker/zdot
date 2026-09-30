#!/usr/bin/env zsh
# docker: Docker completions manager environment

_docker_init() {
    # .zshrc only loads this module on macOS, but guard defensively
    if [[ -d ~/.docker/ ]]; then
        if [[ -d ~/.docker/bin ]]; then
            export PATH="${PATH}:${HOME}/.docker/bin"
        fi
        if [[ -d ~/.docker/completions/ ]]; then
            zdot_add_fpath "${HOME}/.docker/completions" --glob '_*'
        fi
        if command -v docker &>/dev/null; then
            if (( ! $+DOCKER_HOST )); then
                export DOCKER_HOST=`docker context ls --format json | jq -r 'select(.Current) | .DockerEndpoint'`
            fi
        fi
    fi
}

zdot_simple_hook docker --provides docker-ready --group completions-producers
