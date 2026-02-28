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
# NOTE: Using :a (absolute path) instead of :A to preserve symlinks
local zdot_core_dir="${${(%):-%x}:a:h}/core"

# Source base first (needed by other components)
source "${zdot_core_dir}/ctx.zsh"

# Source logging (needed by other components)
source "${zdot_core_dir}/logging.zsh"

# Source all components in dependency order
source "${zdot_core_dir}/core.zsh"
source "${zdot_core_dir}/cache.zsh"
source "${zdot_core_dir}/hooks.zsh"
source "${zdot_core_dir}/modules.zsh"
source "${zdot_core_dir}/functions.zsh"
source "${zdot_core_dir}/completions.zsh"
source "${zdot_core_dir}/utils.zsh"
source "${zdot_core_dir}/plugins.zsh"
source "${zdot_core_dir}/init.zsh"
source "${zdot_core_dir}/update.zsh"

# Source plugin bundles
source "${zdot_core_dir}/compinit.zsh"              # shared compinit (before any bundle)
source "${zdot_core_dir}/plugin-bundles/omz.zsh"
source "${zdot_core_dir}/plugin-bundles/pz.zsh"

# Early plugin initialization: clone/cache required plugins BEFORE hooks run
_zdot_plugins_init

# Initialize cache system (reads zstyle configuration from .zshrc)
zdot_cache_init

# Autoload core functions (with cache compilation if enabled)
local core_functions_dir="${zdot_core_dir}/functions"
if [[ -d "$core_functions_dir" ]]; then
    # Compile functions if caching is enabled
    if zdot_cache_is_enabled; then
        zdot_cache_compile_functions "$core_functions_dir"
    fi

    # Add to fpath and autoload all functions
    fpath=("$core_functions_dir" $fpath)
    for func_file in "$core_functions_dir"/*; do
        [[ -f "$func_file" ]] || continue
        # Skip completion functions (_*) — compinit discovers them via fpath
        [[ "${func_file:t}" == _* ]] && continue
        autoload -Uz "${func_file:t}"
    done
fi

# Autoload user functions
zdot_autoload_global_funcs

# Explicitly autoload _zdot as a shell function.
# The loop above skips _* files because compinit normally owns completion
# function registration. However, compdef only maps a command to a completion
# function name — it does NOT autoload the function itself. Without an explicit
# autoload here, zsh cannot find _zdot when tab-completion fires.
# (_zdot has a #compdef zdot header so compinit handles the mapping itself.)
autoload -Uz _zdot

unset zdot_core_dir core_functions_dir

# Mark zdot as loaded
_ZDOT_MODULES_LOADED[zdot]=1
