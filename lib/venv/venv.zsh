#!/usr/bin/env zsh
# venv: Python virtual environment management

# ============================================================================
# Module Initialization
# ============================================================================

_venv_init() {
    # Set default Python version based on OS
    if is-macos; then
        DEFAULT_PYTHON_VERSION=`which python3.14`
        export UV_NO_MANAGED_PYTHON=1
    else
        DEFAULT_PYTHON_VERSION='cpython@3.14.0'
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
zdot_hook_register pre-plugin _venv_init interactive noninteractive
zdot_hook_register after-secrets _activate_global_venv interactive noninteractive

# Lazy load module functions
zdot_module_autoload_funcs
