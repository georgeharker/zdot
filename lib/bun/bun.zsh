#!/usr/bin/env zsh
# bun: Bun toolchain and cargo environment
# Manages Bun installation and completions

# Register completions
zdot_completion_register_file "bub" "bun completions zsh > $(_zdot_completions_dir)/_bun"
