#!/usr/bin/env zsh
# Plugins: zdot-plugins manager setup
# Uses zdot-plugins for plugin management (now in core/plugins.zsh)

# ============================================================================
# Plugin Configuration (zstyles for OMZ plugins)
# ============================================================================

_omz_configure_update() {
    zstyle ':omz:update' mode prompt
}

zdot_hook_register _omz_configure_update interactive noninteractive \
    --name omz-configure-update \
    --group omz-configure

_plugins_configure() {
    zstyle ':omz:plugins:eza' 'dirs-first' yes
    zstyle ':omz:plugins:eza' 'git-status' yes
    zstyle ':omz:plugins:eza' 'icons' yes

    if ! zdot_interactive || [[ -n "$NVIM" ]]; then
        zstyle ':omz:plugins:nvm' lazy no
    else
        zstyle ':omz:plugins:nvm' lazy yes
    fi

    zstyle ':omz:plugins:nvm' autoload no
    zstyle ':omz:plugins:nvm' lazy-cmd opencode mcp-hub copilot prettierd claude-code

    export NVM_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvm"
    if [[ -f "$NVM_DIR/nvm.sh" ]]; then
        if zdot_is_newer_or_missing "$NVM_DIR/nvm.sh" "$NVM_DIR/nvm.sh.zwc"; then
            zcompile "$NVM_DIR/nvm.sh"
        fi
    fi

    # Fast-syntax-highlighting
    FAST_WORK_DIR=XDG:fast-syntax-highlighting

    # Zsh-autosuggest
    ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd abbreviations completion)

    # Zsh-abbr
    ABBR_AUTOLOAD=1
    ABBR_SET_EXPANSION_CURSOR=1
    ABBR_SET_LINE_CURSOR=1
    ABBR_GET_AVAILABLE_ABBREVIATION=1
    ABBR_USER_ABBREVIATIONS_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-abbr/user-abbreviations
}

# ============================================================================
# Plugin Declarations
# ============================================================================

# OMZ lib and plugins (from ohmyzsh/ohmyzsh)
zdot_use omz:lib
zdot_use omz:plugins/git
zdot_use omz:plugins/tmux
zdot_use omz:plugins/fzf
zdot_use omz:plugins/zoxide
zdot_use omz:plugins/npm
zdot_use omz:plugins/nvm
zdot_use omz:plugins/eza
zdot_use omz:plugins/ssh
zdot_use omz:plugins/debian

# Abbreviations support
zdot_use olets/zsh-abbr defer \
    --name zsh-abbr-load \
    --provides abbr-ready \
    --requires omz-plugins-loaded

# Syntax highlighting (deferred for faster startup)
zdot_use zdharma-continuum/fast-syntax-highlighting defer \
    --name fsh-load \
    --provides fsh-ready \
    --requires omz-plugins-loaded

# fast-abbr highlighting (requires FSH)
zdot_use 5A6F65/fast-abbr-highlighting defer \
    --name fast-abbr-load \
    --provides fast-abbr-ready \
    --requires fsh-ready

# Autosuggestions (deferred)
zdot_use zsh-users/zsh-autosuggestions defer \
    --name autosuggest-load \
    --provides autosuggest-ready \
    --requires omz-plugins-loaded

# autosuggest abbreviations strategy
zdot_use olets/zsh-autosuggestions-abbreviations-strategy defer \
    --name autosuggest-abbr-load \
    --provides autosuggest-abbr-ready \
    --requires autosuggest-ready

# fzf tab completion (must be last)
zdot_use Aloxaf/fzf-tab

# Register plugin configuration hook
zdot_hook_register _plugins_configure interactive noninteractive \
    --name plugins-configure \
    --requires xdg-configured


# OMZ Library Loader (called when needed)
# Uses omz.zsh bundle for compdef queue and compinit deferral
# ============================================================================

_plugins_load_omz() {
    zdot_load_plugin omz:lib
    zdot_load_plugin omz:plugins/git
    zdot_load_plugin omz:plugins/tmux
    # fzf keybindings require a PTY; skip the plugin in non-PTY contexts to
    # avoid "(eval):1: can't change option: zle" errors from fzf --zsh's
    # option-snapshot/restore blocks.
    zdot_has_tty && zdot_load_plugin omz:plugins/fzf
    zdot_verify_tools fzf
    zdot_load_plugin omz:plugins/zoxide
    zdot_load_plugin omz:plugins/npm
    zdot_load_plugin omz:plugins/nvm
    zdot_load_plugin omz:plugins/eza
    zdot_load_plugin omz:plugins/ssh
    if [[ $(uname -v 2>/dev/null) == *"Debian"* || $(uname -v 2>/dev/null) == *"Ubuntu"* ]]; then
        zdot_load_plugin omz:plugins/debian
    fi
}

# Register phase for when OMZ lib is ready
# Note: _plugins_load_omz handles non-interactive gracefully (skips compinit)
zdot_hook_register _plugins_load_omz interactive noninteractive \
    --name omz-loader \
    --group omz-plugins \
    --requires plugins-cloned \
    --requires omz-bundle-initialized \
    --provides omz-plugins-loaded \
    --requires-tool tmux \
    --provides-tool fzf \
    --provides-tool nvm

# ============================================================================
# Compinit (deferred, after all deferred plugins are fpath-registered)
# ============================================================================

zdot_hook_register zdot_compinit_defer interactive noninteractive \
    --name compinit-defer \
    --deferred \
    --requires autosuggest-abbr-ready \
    --provides compinit-done

# ============================================================================
# Non-deferred plugins (fzf-tab)
# ============================================================================

# fzf-tab explicitly handles being initialized before compinit (see fzf-tab.zsh
# line 376-379: it pre-creates the completion widget when compinit hasn't run
# yet). Compinit itself is enqueued at the end of zdot_load_deferred_plugins
# via zdot_defer, so it runs after all deferred plugin fpath additions.
_plugins_load_fzf_tab() {
    zdot_load_plugin Aloxaf/fzf-tab
}

zdot_hook_register _plugins_load_fzf_tab interactive \
    --name fzf-tab-loader \
    --requires autosuggest-abbr-ready \
    --provides fzf-tab-loaded

# ============================================================================
# Post-Load Setup
# ============================================================================

_plugins_post_init() {
    # Fast-syntax-highlighting theme (after plugins load)
    if zdot_interactive; then
        if [[ -f ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini ]]; then
            if [[ ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini:A -nt ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/current_theme.zsh:A ]]; then
                zdot_defer -q fast-theme -q ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini
            fi
        fi
    fi
}

zdot_hook_register _plugins_post_init interactive noninteractive \
    --name plugins-post \
    --deferred \
    --requires autosuggest-abbr-ready \
    --provides plugins-post-configured

# ============================================================================
# NVM Initialization
# ============================================================================

_nvm_interactive_init() {
    (( ${+functions[nvm]} )) || return 0
    # -q suppresses precmd hooks and zle reset-prompt after the deferred call,
    # preventing oh-my-posh's built-in newline in PS1 from producing a spurious
    # blank line before the next prompt.
    zdot_defer_until -q 1 nvm use node --silent
}

_nvm_noninteractive_init() {
    # Only run if nvm shell function is available
    (( ${+functions[nvm]} )) || return 0
    nvm use node --silent >/dev/null
}

zdot_hook_register _nvm_interactive_init interactive \
    --name nvm \
    --deferred \
    --requires plugins-post-configured \
    --requires-tool nvm \
    --provides nvm-ready

zdot_hook_register _nvm_noninteractive_init noninteractive \
    --name nvm-noninteractive \
    --requires omz-plugins-loaded \
    --provides nvm-ready

# Accept intentional force-deferral for hooks whose required phases are
# provided by explicitly --deferred hooks
zdot_accept_deferred _fzf_post_plugin
zdot_accept_deferred _plugins_load_fzf_tab
zdot_accept_deferred _completions_finalize
zdot_accept_deferred _keybinds_init
zdot_accept_deferred _aliases_init
zdot_accept_deferred _prompt_init

# zdot_init is called from .zshenv after all modules have loaded
