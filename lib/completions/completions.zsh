#!/usr/bin/env zsh
# completions: Shell completion management system
# Executes registered file-based and live completions

# Autoload module functions immediately
zdot_module_autoload_funcs

# Set up completion paths (adds directories to fpath)
zdot_completions_setup() {
    local completions_dir="$(_zdot_completions_dir)"
    
    # Add global completions directory to fpath
    if [[ -d "$completions_dir" ]]; then
        fpath=("$completions_dir" $fpath)
    fi

    # Add per-module completion directories to fpath
    for module_dir in "$_ZDOT_LIB_DIR"/*(/); do
        local comp_dir="${module_dir}/completions"
        if [[ -d "$comp_dir" ]]; then
            fpath=("$comp_dir" $fpath)
        fi
    done
}

# Run all live completion registrations
zdot_completions_run_live() {
    for func in "${_ZDOT_COMPLETION_LIVE[@]}"; do
        if typeset -f "$func" > /dev/null; then
            "$func"
        else
            echo "completions: live function '${func}' not found" >&2
        fi
    done
}

# Module initialization
_completions_init() {
    # Register standard file-based completions
    zdot_completion_register_file "gh" "gh completion -s zsh"
    zdot_completion_register_file "tailscale" "tailscale completion zsh"
}

# Register hooks
#zdot_hook_register post-plugin _completions_run_live
