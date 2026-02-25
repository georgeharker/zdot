#!/usr/bin/env zsh
# Prompt module
# Oh-my-posh prompt configuration

_prompt_init() {
    # Oh-my-posh (should be at the end)
    if command -v oh-my-posh &> /dev/null; then
        # zdot_defer eval "$(oh-my-posh init zsh --config $HOME/.config/oh-my-posh/theme.toml)"
        eval "$(oh-my-posh init zsh --config $HOME/.config/oh-my-posh/theme.toml)"
    fi
}

# Register hook: requires plugins to be loaded (for zdot_defer function), runs late
# Prompt only needed in interactive shells
zdot_hook_register _prompt_init interactive \
    --name prompt \
    --deferred-prompt \
    --requires plugins-post-configured \
    --requires-tool oh-my-posh \
    --provides prompt-ready
