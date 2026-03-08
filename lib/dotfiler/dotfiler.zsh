#!/usr/bin/env zsh
# Dotfiler module
# Dotfiler repository update checker and custom scripts
#
# Configuration:
#   zstyle ':zdot:dotfiler' scripts-dir  '/path/to/dotfiler'
#
#   Specifies the directory containing the dotfiler scripts
#   (check_update.zsh, completions.zsh, etc.).
#
#   Resolution order (first match wins):
#     1. zstyle ':zdot:dotfiler' scripts-dir  (explicit override)
#     2. ${XDG_DATA_HOME}/dotfiler            (XDG conventional location)
#     3. ${HOME}/.dotfiles/.nounpack/dotfiler (conventional dotfiler repo layout)
#
#   This is the same zstyle key read by the zdot self-update system in
#   core/update.zsh, so setting it once configures both.

_dotfiler_get_scripts_dir() {
    local _dir
    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _dir && [[ -n "$_dir" ]] && {
        print -n "$_dir"; return 0
    }
    # 2. XDG conventional location
    _dir="${XDG_DATA_HOME:-${HOME}/.local/share}/dotfiler"
    [[ -d "$_dir" ]] && { print -n "$_dir"; return 0 }
    # 3. Conventional dotfiler repo layout
    _dir="${HOME}/.dotfiles/.nounpack/dotfiler"
    [[ -d "$_dir" ]] && { print -n "$_dir"; return 0 }
    return 1
}

_dotfiler_init() {
    zstyle ':dotfiler:update' mode prompt

    local _dotfiler_scripts
    _dotfiler_scripts=$(_dotfiler_get_scripts_dir) || return 0

    # Compile dotfiler scripts to .zwc for faster sourcing
    if zdot_cache_is_enabled; then
        zdot_cache_compile_functions "$_dotfiler_scripts" '*.zsh'
    fi

    # Source dotfiles update checker (requires GH_TOKEN from 1Password)
    [[ -f "${_dotfiler_scripts}/check_update.zsh" ]] && \
        source "${_dotfiler_scripts}/check_update.zsh"

    # Source dotfiles completions
    [[ -f "${_dotfiler_scripts}/completions.zsh" ]] && \
        source "${_dotfiler_scripts}/completions.zsh"
}

# Register hook: requires secrets for GH_TOKEN
# Only needed in interactive shells
zdot_simple_hook dotfiler --requires secrets-loaded --provides dotfiler-ready --context interactive
