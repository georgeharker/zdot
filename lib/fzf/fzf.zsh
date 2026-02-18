#!/usr/bin/env zsh
# fzf: FZF configuration and helper functions

# ============================================================================
# Module Initialization
# ============================================================================

_fzf_init() {
    # disable sort when completing `git checkout`
    zstyle ':completion:*:git-checkout:*' sort false

    # set descriptions format to enable group support
    # NOTE: don't use escape sequences (like '%F{red}%d%f') here, fzf-tab will ignore them
    # zstyle ':completion:*:descriptions' format '[%U%B%d%b%u]'

    # force zsh not to show completion menu, which allows fzf-tab to capture the unambiguous prefix
    zstyle ':completion:*' menu no

    # preview directory's content with eza when completing cd
    zstyle ':fzf-tab:complete:cx:*' fzf-preview 'eza -1 --color=always --icons $realpath'

    # custom fzf flags
    # NOTE: fzf-tab does not follow FZF_DEFAULT_OPTS by default
    # zstyle ':fzf-tab:*' fzf-flags --color=fg:1,fg+:2 --bind=tab:accept

    # To make fzf-tab follow FZF_DEFAULT_OPTS.
    # NOTE: This may lead to unexpected behavior since some flags break this plugin. See Aloxaf/fzf-tab#455.
    zstyle ':fzf-tab:*' use-fzf-default-opts yes

    # Tab to accept in fzf
    zstyle ':fzf-tab:*' fzf-bindings "tab:accept"

    # switch group using `<` and `>`
    zstyle ':fzf-tab:*' switch-group '<' '>'

    # zstyle ':fzf-tab:*' debug-command 'printf "$FZF_DEFAULT_OPTS"'

    # NOTE: fzf-tab forces heights, so fzf must set FZF_TMUX_HEIGHT to override,
    # which will be ignored by fzf if FZF_DEFAULT_OPTS is set
}

_fzf_post_plugin_keybinds() {
    # Autosuggest control
    bindkey '^K' autosuggest-clear

    # FZF ZLE widgets (must be registered after fzf functions are loaded)
    zle -N zle_fzf_rg
    zle -N zle_fzf_ripgrep
    zle -N zle_fzf_fd

    bindkey '^Fg' zle_fzf_rg
    bindkey '^Fr' zle_fzf_ripgrep
    bindkey '^Ff' zle_fzf_fd
}

_fzf_post_plugin() {
    # Load fzf theme
    [ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/tokyonight_night.sh" ] && \
        source "${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/tokyonight_night.sh"

    # Load fzf shell integration
    [ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/fzf.zsh" ] && \
        source "${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/fzf.zsh"

    _fzf_post_plugin_keybinds

    # enable fzf-tab
    if typeset -f enable-fzf-tab &> /dev/null; then
        enable-fzf-tab
    fi
}

# Register hooks
# Pre-plugin: configure fzf-tab zstyles before plugin loads
zdot_hook_register _fzf_init interactive \
    --requires xdg-configured \
    --provides fzf-configured

# Post-plugin: setup fzf after plugins are loaded
zdot_hook_register _fzf_post_plugin interactive \
    --requires plugins-loaded \
    --provides fzf-ready

# Lazy load module functions
zdot_module_autoload_funcs
