#!/usr/bin/env zsh
# go: Go toolchain and environment
# Manages Bun installation and completions

# Requires
# zstyle ':zdot:brew' verify-tools go
# zstyle ':zdot:apt' verify-tools go

_go_init() {
    # For completions
    zdot_load_plugin omz:golang

    # set up path
    export PATH="${PATH}:$(go env GOBIN)"
}

zdot_use_plugin omz:golang

# --group completions-producers: _go_init registers completions in its body,
# so completions finalization must wait for it (see modules/completions).
zdot_simple_hook go --provides go-ready \
    --requires-group go-configure \
    --requires bootstrap-ready \
    --requires-tool go \
    --group completions-producers
