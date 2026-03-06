#!/usr/bin/env zsh
# xdg: XDG Base Directory setup
# Foundation module - provides xdg-configured phase

function is-macos() {
    [[ $OSTYPE == darwin* ]]
}

function is-debian() {
    [[ $OSTYPE == linux* && -f /etc/debian_version ]]
}

# Check if the current platform matches any of the given names or globs.
# Friendly aliases: 'mac' -> darwin*, 'linux' -> linux*, 'debian' -> linux* + /etc/debian_version
# Raw $OSTYPE globs (e.g. 'darwin*', 'linux-gnu*') are also accepted.
# Usage: if is-platform mac debian; then ...
#        if is-platform 'darwin*' linux; then ...
function is-platform() {
    local name
    for name in "$@"; do
        case "$name" in
            mac)    [[ $OSTYPE == darwin* ]]                                  && return 0 ;;
            linux)  [[ $OSTYPE == linux* ]]                                   && return 0 ;;
            debian) [[ $OSTYPE == linux* && -f /etc/debian_version ]]         && return 0 ;;
            *)      [[ $OSTYPE == ${~name} ]]                                 && return 0 ;;
        esac
    done
    return 1
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
# xdg is a foundation module - no dependencies, provides xdg-configured phase
zdot_register_hook _xdg_init interactive noninteractive --provides xdg-configured
# Cleanup hook runs at the end of deferred dispatch as a finally-group member
zdot_register_hook _xdg_cleanup interactive noninteractive --group finally
