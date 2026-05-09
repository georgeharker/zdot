#!/usr/bin/env zsh
# venv: Python virtual environment management
#
# To configure Python versions, register a hook into the venv-configure group:
#
#   _my_venv_config() {
#       zstyle ':zdot:venv' python-version-macos '/opt/homebrew/bin/python3.13'
#       zstyle ':zdot:venv' python-version-linux 'cpython@3.13.0'
#   }
#   zdot_register_hook _my_venv_config interactive noninteractive \
#       --group venv-configure

# ============================================================================
# Module Initialization
# ============================================================================

_venv_init() {
    # Read Python version from zstyle, with OS-appropriate defaults.
    #
    # On macOS the default resolves to the Homebrew-managed python3.14 binary.
    # This is intentional — see README.md for the rationale around dyld paths
    # and Homebrew-linked native libraries.
    #
    # On Linux the default uses uv's managed CPython distribution.
    if is-macos; then
        local default_python="$(command -v python3.14 2>/dev/null || echo python3)"
        zstyle -s ':zdot:venv' python-version-macos DEFAULT_PYTHON_VERSION \
            || DEFAULT_PYTHON_VERSION="$default_python"
        export UV_NO_MANAGED_PYTHON=1
    else
        zstyle -s ':zdot:venv' python-version-linux DEFAULT_PYTHON_VERSION \
            || DEFAULT_PYTHON_VERSION='cpython@3.14.0'  # shuck: ignore=C001
        export UV_MANAGED_PYTHON=1
    fi

    # Python venv aliases
    alias npvenv='nvenv pypy3 .pypyvenv'
    alias rpvenv='rvenv pypy3 .pypyvenv'
    alias apvenv='avenv .pypyvenv'
}

_activate_global_venv() {
    # Global Python virtualenv
    [ -f ~/.venv/bin/activate ] && source ~/.venv/bin/activate
}

# Register hooks
zdot_register_hook _venv_init interactive noninteractive \
    --requires xdg-configured \
    --requires-group venv-configure \
    --provides venv-configured

zdot_register_hook _activate_global_venv interactive noninteractive \
    --requires venv-configured \
    --optional secrets-loaded \
    --provides venv-ready

# Lazy load module functions
zdot_module_autoload_funcs
