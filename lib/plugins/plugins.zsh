#!/usr/bin/env zsh
# Plugins: Antidote/Oh-My-Zsh plugin manager setup
# Settings for oh-my-zsh plugins and related tools

_plugins_init() {
    # Oh My Zsh update settings
    zstyle ':omz:update' mode prompt

    # Plugin-specific configuration
    zstyle ':omz:plugins:eza' 'dirs-first' yes
    zstyle ':omz:plugins:eza' 'git-status' yes
    zstyle ':omz:plugins:eza' 'icons' yes

    # nvm
    if zdot_interactive; then
        zstyle ':omz:plugins:nvm' lazy yes
    else
        zstyle ':omz:plugins:nvm' lazy no
    fi
    zstyle ':omz:plugins:nvm' autoload no
    zstyle ':omz:plugins:nvm' lazy-cmd opencode mcp-hub copilot prettierd claude-code
    export NVM_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvm"

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

_antidote_load() {
    export ANTIDOTE_HOME=${XDG_CACHE_HOME:-${HOME}/.cache/}/antidote
    [[ ! -d ${ANTIDOTE_HOME} ]] && mkdir -p ${ANTIDOTE_HOME}

    if [[ -f ${XDG_DATA_HOME:-${HOME}/.local/share}/antidote/antidote.zsh ]]; then
        source ${XDG_DATA_HOME:-${HOME}/.local/share}/antidote/antidote.zsh

        export ZSH=$(antidote path ohmyzsh/ohmyzsh)
        export ZSH_CUSTOM=${XDG_DATA_HOME:-${HOME}/.local/share}/oh-my-zsh/

        zsh_plugins=${XDG_CONFIG_HOME:-${HOME}/.config}/antidote/zsh_plugins

        zstyle ':antidote:bundle' file ${zsh_plugins}.conf
        zstyle ':antidote:static' file ${zsh_plugins}.zsh

        antidote load
    else
        # oh-my-zsh init fallback
        export ZSH="${HOME}/.oh-my-zsh"

        # Which plugins would you like to load?
        # Standard plugins can be found in $ZSH/plugins/
        # Custom plugins may be added to $ZSH_CUSTOM/plugins/
        # Example format: plugins=(rails git textmate ruby lighthouse)
        # Add wisely, as too many plugins slow down shell startup.
        plugins=(git tmux fzf nvm per-directory-history zsh-autosuggestions fzf-tab zoxide)

        source "${ZSH}/oh-my-zsh.sh"
    fi

    # Check if zsh-defer is available
    zsh_defer=''
    if command -v zsh-defer &> /dev/null; then
        zsh_defer='zsh-defer'
    fi
}

_plugins_post_init() {
    # Fast-syntax-highlighting theme (after plugins load)
    if [[ $(realpath ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini) -nt ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/current_theme.zsh ]]; then
        ${zsh_defer} fast-theme ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini
    fi
}

# Register hooks
zdot_hook_register pre-plugin _plugins_init interactive noninteractive
zdot_hook_register plugin-load _antidote_load interactive noninteractive
zdot_hook_register post-plugin _plugins_post_init interactive noninteractive
