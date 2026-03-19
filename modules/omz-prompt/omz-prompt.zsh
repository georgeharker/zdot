#!/usr/bin/env zsh
# omz-prompt: oh-my-zsh theme-based prompt
#
# Activates an oh-my-zsh theme as the shell prompt. Provides 'prompt-ready'.
# Only one prompt module should be loaded at a time.
#
# Load in your .zshrc (alongside the omz bundle):
#   zdot_load_module omz-prompt
#
# Configuration (required — no default theme is assumed):
#   zstyle ':zdot:omz-prompt' theme 'robbyrussell'
#
# For themes with extra setup (e.g. powerlevel10k), register a hook into
# the omz-prompt-configure group before this module runs.

_omz_prompt_init() {
    local _theme
    zstyle -s ':zdot:omz-prompt' theme _theme || {
        zdot_warn "omz-prompt: no theme set; use: zstyle ':zdot:omz-prompt' theme '<name>'"
        return 1
    }

    [[ -z "${ZSH:-}" ]] && {
        zdot_warn "omz-prompt: ZSH (oh-my-zsh root) is not set; is the omz bundle loaded?"
        return 1
    }

    ZSH_THEME="$_theme"
    local _theme_file="${ZSH}/themes/${_theme}.zsh-theme"
    [[ -f "$_theme_file" ]] || _theme_file="${ZSH_CUSTOM:-$ZSH/custom}/themes/${_theme}.zsh-theme"

    if [[ -f "$_theme_file" ]]; then
        source "$_theme_file"
    else
        zdot_warn "omz-prompt: theme file not found for '${_theme}'"
        return 1
    fi
}

zdot_register_hook _omz_prompt_init interactive \
    --name omz-prompt \
    --requires xdg-configured \
    --requires-group omz-prompt-configure \
    --provides prompt-ready \
    --optional
