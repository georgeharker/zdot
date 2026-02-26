#!/usr/bin/env zsh
# nodejs: nvm and npm OMZ plugin integration

# ============================================================================
# Configuration
# ============================================================================

_node_configure() {
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
}

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
    (( ${+functions[nvm]} )) || return 0
    nvm use node --silent >/dev/null
}

# ============================================================================
# Module Definition
# ============================================================================

zdot_define_module node \
    --configure _node_configure \
    --load-plugins omz:plugins/npm omz:plugins/nvm \
    --auto-bundle \
    --provides-tool nvm \
    --interactive-init _nvm_interactive_init \
    --noninteractive-init _nvm_noninteractive_init
