#!/usr/bin/env zsh
# completions: Shell completion management system
# Executes registered file-based and live completions

# Autoload module functions immediately
zdot_module_autoload_funcs

# Module initialization - Phase 1: Setup fpath and register file completions
_completions_init() {
    # Add completion directories to fpath
    local completions_dir=$(zdot_get_completions_dir)

    # Add global completions directory to fpath
    if [[ -d "$completions_dir" ]]; then
        fpath=("$completions_dir" $fpath)
    fi

    # Add per-module completion directories to fpath.
    # Uses the loaded-module map so user-path modules are included alongside lib/ modules.
    local _mod _mod_dir
    for _mod in "${(k)_ZDOT_MODULE_SOURCE_DIR}"; do
        _mod_dir="${_ZDOT_MODULE_SOURCE_DIR[$_mod]}"
        local comp_dir="${_mod_dir}/completions"
        if [[ -d "$comp_dir" ]]; then
            fpath=("$comp_dir" $fpath)
        fi
    done
    
    # Register standard file-based completions
    zdot_register_completion_file "gh" "gh completion -s zsh"
    zdot_register_completion_file "tailscale" "tailscale completion zsh"
    zdot_register_completion_file "sharedserver" "sharedserver completion zsh"
}

# Phase 2: Run live completions and lazy-refresh file completions after tools are available
_completions_finalize() {
    lazy_refresh_completions

    for func in "${_ZDOT_COMPLETION_LIVE[@]}"; do
        if typeset -f "$func" > /dev/null; then
            "$func"
        else
            zdot_error "completions: live function '${func}' not found"
        fi
    done
}

# Register hooks
# Phase 1: Early fpath setup (before compinit)
zdot_register_hook _completions_init interactive \
    --requires xdg-configured \
    --provides completions-paths-ready

# Phase 2: Late live completions (after tools available)
zdot_register_hook _completions_finalize interactive \
    --requires completions-paths-ready autocomplete-post-configured rust-ready bun-ready uv-configured \
    --provides completions-ready
