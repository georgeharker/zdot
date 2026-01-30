#!/usr/bin/env zsh
# xdg: XDG Base Directory setup
# Must be loaded in bootstrap phase as everything depends on it

function is-macos() {
    [[ $OSTYPE == darwin* ]]
}

function is-debian() {
    [[ $OSTYPE == linux* && -f /etc/debian_version ]]
}

function src-newer-or-dest-missing() {
    local src="$1"
    local dst="$2"
    [[ ! -f "${dst}" || ( -f "${src}" && ( $(realpath "${src}") -nt "${dst}" ) ) ]]
}

xdg_runtime_dir() {
    if is-macos; then
        export XDG_RUNTIME_DIR=$(getconf DARWIN_USER_TEMP_DIR)
        mkdir -p "${XDG_RUNTIME_DIR}"
    else
        if [[ "${XDG_RUNTIME_DIR}" == "" ]]; then
            export XDG_RUNTIME_DIR="/run/user/$(id -u)"
            mkdir -p "${XDG_RUNTIME_DIR}"
        fi
    fi
}

xdg_mutable_dirs() {
    local homedir=$1
    export XDG_DATA_HOME="${homedir}/.local/share"
    export XDG_CACHE_HOME="${homedir}/.cache"
    export XDG_STATE_HOME="${homedir}/.local/state"
    xdg_runtime_dir "${homedir}"
}

xdg_config_dirs() {
    local homedir=$1
    export XDG_CONFIG_HOME="${homedir}/.config"
    export XDG_BIN_HOME="${homedir}/.local/bin"
}

xdg_dirs() {
    local homedir=$1
    xdg_mutable_dirs ${homedir}
    xdg_config_dirs ${homedir}
}

undef_xdg_fns() {
    unset -f xdg_runtime_dir
    unset -f xdg_mutable_dirs
    unset -f xdg_config_dirs
    unset -f xdg_dirs
}

# Module initialization function
_xdg_init() {
    # Initialize XDG directories
    xdg_dirs "${HOME}"
}

# Module cleanup function
_xdg_cleanup() {
    undef_xdg_fns
}

# Register hooks
zdot_hook_register bootstrap _xdg_init interactive noninteractive
zdot_hook_register finalize _xdg_cleanup interactive noninteractive
