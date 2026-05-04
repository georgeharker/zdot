#!/usr/bin/env zsh
# fzf: FZF configuration and helper functions

# ============================================================================
# OMZ Completion Configuration (shared omz-configure group)
# ============================================================================

_omz_configure_completion() {
    # disable sort when completing `git checkout`
    zstyle ':completion:*:git-checkout:*' sort false

    # set descriptions format to enable group support
    # NOTE: don't use escape sequences (like '%F{red}%d%f') here, fzf-tab will ignore them
    # zstyle ':completion:*:descriptions' format '[%U%B%d%b%u]'

    # force zsh not to show completion menu, which allows fzf-tab to capture the unambiguous prefix
    zstyle ':completion:*' menu no
}

zdot_register_hook _omz_configure_completion interactive noninteractive \
    --name omz-configure-completion \
    --group omz-configure

# ============================================================================
# Plugin Declarations
# ============================================================================

zdot_use_plugin omz:plugins/fzf
zdot_use_plugin Aloxaf/fzf-tab

# ============================================================================
# fzf Core Module (configure -> load -> post-init)
# ============================================================================

_fzf_plugins_load_omz() {
    zdot_has_tty && zdot_load_plugin omz:plugins/fzf
    zdot_verify_tools fzf
}

_fzf_init() {
    # preview directory's content with eza when completing the zoxide jump command.
    # Only registered if ZOXIDE_CMD_OVERRIDE is set (the completion target name varies).
    if [[ -n "${ZOXIDE_CMD_OVERRIDE}" ]]; then
        # $realpath is set by fzf-tab at preview time — single quotes are intentional
        zstyle ":fzf-tab:complete:${ZOXIDE_CMD_OVERRIDE}:*" fzf-preview 'eza -1 --color=always --icons $realpath'
    fi

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
    # Configure via: zstyle ':zdot:fzf' theme '/path/to/theme.sh'
    # Set to empty string to disable theme loading entirely.
    local _fzf_default_theme="${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/tokyonight_night.sh"
    local _fzf_theme
    zstyle -s ':zdot:fzf' theme _fzf_theme || _fzf_theme="${_fzf_default_theme}"
    [[ -n "${_fzf_theme}" && -f "${_fzf_theme}" ]] && source "${_fzf_theme}"

    # Load fzf shell integration
    [ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/fzf.zsh" ] && \
        source "${XDG_CONFIG_HOME:-${HOME}/.config}/fzf/fzf.zsh"

    _fzf_post_plugin_keybinds

    # enable fzf-tab
    if typeset -f enable-fzf-tab &> /dev/null; then
        enable-fzf-tab
    fi
}

zdot_define_module fzf \
    --configure _fzf_init \
    --load _fzf_plugins_load_omz \
    --post-init _fzf_post_plugin \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized \
    --provides-tool fzf

# ============================================================================
# fzf-tab Module (separate load phase, interactive only)
# ============================================================================

_plugins_load_fzf_tab() {
    zdot_load_plugin Aloxaf/fzf-tab
}

zdot_define_module fzf-tab \
    --load _plugins_load_fzf_tab \
    --requires autosuggest-abbr-ready fzf-configured \
    --context interactive

# Lazy load module functions
zdot_module_autoload_funcs
