#!/usr/bin/env zsh
# Prompt module
# Oh-my-posh prompt configuration

_prompt_init() {
    # Oh-my-posh (should be at the end)
    if command -v oh-my-posh &> /dev/null; then
        ${zsh_defer} eval "$(oh-my-posh init zsh --config $HOME/.config/oh-my-posh/theme.toml)"
    fi
}

# Register hook for finalize phase
# Prompt only needed in interactive shells
zdot_hook_register finalize _prompt_init interactive
