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
    if ! zdot_interactive || [[ ! -z "$NVIM" ]]; then
        zstyle ':omz:plugins:nvm' lazy no
    else
        zstyle ':omz:plugins:nvm' lazy yes
    fi
    zstyle ':omz:plugins:nvm' autoload no
    zstyle ':omz:plugins:nvm' lazy-cmd opencode mcp-hub copilot prettierd claude-code
    export NVM_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvm"

    # Ensure nvm.sh is compiled for faster loading
    if [[ -f "$NVM_DIR/nvm.sh" ]]; then
        # Compile if .zwc doesn't exist or is older than nvm.sh
        if [[ ! -f "$NVM_DIR/nvm.sh.zwc" ]] || [[ "$NVM_DIR/nvm.sh:A" -nt "$NVM_DIR/nvm.sh.zwc:A" ]]; then
            zcompile "$NVM_DIR/nvm.sh"
        fi
    fi

    # Fast-syntax-highlighting
    FAST_WORK_DIR=XDG:fast-syntax-highlighting  # shuck: ignore=C001

    # Zsh-autosuggest
    ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd abbreviations completion)  # shuck: ignore=C001

    # Zsh-abbr
    ABBR_AUTOLOAD=1  # shuck: ignore=C001
    ABBR_SET_EXPANSION_CURSOR=1  # shuck: ignore=C001
    ABBR_SET_LINE_CURSOR=1  # shuck: ignore=C001
    ABBR_GET_AVAILABLE_ABBREVIATION=1  # shuck: ignore=C001
    ABBR_USER_ABBREVIATIONS_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-abbr/user-abbreviations  # shuck: ignore=C001
}

_antidote_load() {
    export ANTIDOTE_HOME=${XDG_CACHE_HOME:-${HOME}/.cache/}/antidote
    [[ ! -d ${ANTIDOTE_HOME} ]] && mkdir -p ${ANTIDOTE_HOME}

    if [[ -f ${XDG_DATA_HOME:-${HOME}/.local/share}/antidote/antidote.zsh ]]; then
        source ${XDG_DATA_HOME:-${HOME}/.local/share}/antidote/antidote.zsh
        
        zstyle ':antidote:bundle' use-friendly-names 'yes'
        
        zsh_plugins=${XDG_CONFIG_HOME:-${HOME}/.config}/antidote/zsh_plugins

        zstyle ':antidote:bundle' file ${zsh_plugins}.conf
        zstyle ':antidote:static' file ${zsh_plugins}.zsh

        zstyle ':antidote:bundle:*' zcompile 'yes'
        zstyle ':antidote:static' zcompile yes

        export ZSH=$(antidote path ohmyzsh/ohmyzsh)
        export ZSH_CUSTOM=${XDG_DATA_HOME:-${HOME}/.local/share}/oh-my-zsh/

        antidote load
    else
        # oh-my-zsh init fallback
        export ZSH="${HOME}/.oh-my-zsh"

        # Which plugins would you like to load?
        # Standard plugins can be found in $ZSH/plugins/
        # Custom plugins may be added to $ZSH_CUSTOM/plugins/
        # Example format: plugins=(rails git textmate ruby lighthouse)
        # Add wisely, as too many plugins slow down shell startup.
        plugins=(git tmux fzf nvm per-directory-history zsh-autosuggestions fzf-tab zoxide)  # shuck: ignore=C001

        source "${ZSH}/oh-my-zsh.sh"
    fi

}

_plugins_post_init() {
    # Fast-syntax-highlighting theme (after plugins load)
    if [[ ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini:A -nt ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/current_theme.zsh:A ]]; then
        zdot_defer fast-theme ${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini
    fi
}

_nvm_interactive_init() {
    # Delay nvm init for interactive until after prompt
    zdot_defer_until 1 nvm use node
}

_nvm_noninteractive_init() {
    nvm use node
}

# No-op hook to satisfy plugins-declared dependency
# zdot_plugins_clone_all in core/plugins.zsh requires this phase unconditionally (bug to fix later)
_plugins_declare_noop() {
    :
}
zdot_register_hook _plugins_declare_noop interactive noninteractive \
    --provides plugins-declared

# Register hooks with dependency chain
# plugins_init prepares plugin configuration, provides plugins-configured
zdot_register_hook _plugins_init interactive noninteractive --requires xdg-configured --provides plugins-configured

# antidote_load actually loads plugins, provides plugins-loaded
zdot_register_hook _antidote_load interactive noninteractive --requires plugins-configured --provides plugins-loaded

# plugins_post_init runs after plugin load, provides plugins-post-configured
zdot_register_hook _plugins_post_init interactive noninteractive --requires plugins-loaded --provides plugins-post-configured

# nvm_interactive_init deferred initialization (interactive only), provides nvm-ready
# Requires prompt-ready to avoid racing with prompt's zsh-defer initialization
zdot_register_hook _nvm_interactive_init interactive --requires prompt-ready --provides nvm-ready
# nvm_noninteractive_init, provides nvm-ready
zdot_register_hook _nvm_noninteractive_init noninteractive --requires plugins-loaded --provides nvm-ready

