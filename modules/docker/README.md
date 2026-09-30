# docker — Docker environment

Initialises Docker's `PATH` and environment variables, completions and DOCKER_HOST.

## Requirements

- Docker must be installed

## What it does

1. Sets `DOCKER_HOST` to the socket for the selected context (using `docker context ls`)
2. Sets `PATH` to include local docker install
3. Sets `FPATH` to include the completions for docker

## Provides

- Phase: `docker-ready`
