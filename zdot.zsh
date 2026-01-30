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

unset zdot_core_dir

# Mark zdot as loaded
_ZDOT_MODULES_LOADED[zdot]=1
