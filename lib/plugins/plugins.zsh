#!/usr/bin/env zsh
# Plugins: zdot-plugins manager setup
# Uses zdot-plugins for plugin management (now in core/plugins.zsh)

# ============================================================================
# Plugin Configuration (zstyles for OMZ plugins)
# ============================================================================

_plugins_configure() {
    zstyle ':omz:update' mode prompt
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
zdot_use_defer olets/zsh-abbr

# Syntax highlighting (deferred for faster startup)
zdot_use_defer zdharma-continuum/fast-syntax-highlighting
zdot_use_defer 5A6F65/fast-abbr-highlighting

# Autosuggestions (deferred)
zdot_use_defer zsh-users/zsh-autosuggestions
zdot_use_defer olets/zsh-autosuggestions-abbreviations-strategy

# fzf tab completion (must be last)
zdot_use Aloxaf/fzf-tab

# Register hook that provides plugins-declared (after declarations are made)
zdot_hook_register _plugins_configure interactive noninteractive \
    --requires xdg-configured \
    --provides plugins-declared

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
    --requires plugins-cloned \
    --provides omz-plugins-loaded

# ============================================================================
# Deferred Plugins Loader
# ============================================================================

_plugins_load_deferred() {
    # Load zsh-defer and all deferred plugins
    zdot_load_deferred_plugins
}

zdot_hook_register _plugins_load_deferred interactive noninteractive \
    --requires omz-plugins-loaded \
    --provides plugins-loaded

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
    --requires plugins-loaded \
    --provides fzf-tab-loaded

# ============================================================================
# Post-Load Setup
# ============================================================================

_plugins_post_init() {
    # Fast-syntax-highlighting theme (after plugins load)
    if zdot_interactive; then
        if [[ -f ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini ]]; then
            if [[ $(realpath ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini) -nt ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/current_theme.zsh ]]; then
                zdot_defer -q fast-theme -q ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini
            fi
        fi
    fi
}

zdot_hook_register _plugins_post_init interactive noninteractive \
    --requires plugins-loaded \
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
    --requires prompt-ready \
    --provides nvm-ready

zdot_hook_register _nvm_noninteractive_init noninteractive \
    --requires plugins-loaded \
    --provides nvm-ready
