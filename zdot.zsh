#!/usr/bin/env zsh
# zdot-core: Core module loading and phase management system
#
# Provides:
#   - Module discovery and loading
#   - Phase-based initialization hooks
#   - Function autoloading helpers
#   - Completion registration system
#
# This is the main entry point that sources all component parts

# Get the directory where core lives
local zdot_core_dir="${${(%):-%x}:A:h}/core"

# Source all components in dependency order
source "${zdot_core_dir}/core.zsh"
source "${zdot_core_dir}/hooks.zsh"
source "${zdot_core_dir}/modules.zsh"
source "${zdot_core_dir}/functions.zsh"
source "${zdot_core_dir}/completions.zsh"
source "${zdot_core_dir}/utils.zsh"

# Autoload core functions
local core_functions_dir="${zdot_core_dir}/functions"
if [[ -d "$core_functions_dir" ]]; then
    fpath=("$core_functions_dir" $fpath)
    for func_file in "$core_functions_dir"/*; do
        [[ -f "$func_file" ]] || continue
        autoload -Uz "${func_file:t}"
    done
fi

unset zdot_core_dir core_functions_dir

# Mark zdot as loaded
_ZDOT_MODULES_LOADED[zdot]=1
