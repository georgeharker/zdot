#!/usr/bin/env zsh
# Shell configuration module
# History settings and shell options

# zstyle ':zdot:history' size           <n>     # HISTSIZE (default: 50000)
# zstyle ':zdot:history' save-size      <n>     # SAVEHIST (default: 100000)
# zstyle ':zdot:history' per-dir        true    # set to false/no/0 to disable per-directory history
# zstyle ':zdot:history' start-global   true    # set to false/no/0 to disable per-directory history
# zstyle ':zdot:history' per-dir-key    '^G'    # set key to toggle global

# Conditionally declare per-directory-history plugin only when it is enabled.
# We must do this at module-load time (before the hook runs) so that
# zdot_load_plugin can find it in the declared-plugin registry.
if zstyle -T ':zdot:history' per-dir; then
    zdot_use_plugin jimhester/per-directory-history
fi

_history_init() {
    # --- optional per-directory history ---
    if zstyle -T ':zdot:history' per-dir; then
        zdot_load_plugin jimhester/per-directory-history
        HISTORY_BASE=${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-directory-history/
        zstyle -T ':zdot:history' start-global HISTORY_START_WITH_GLOBAL
        if ! zstyle -s ':zdot:history' per-dir-key PER_DIRECTORY_HISTORY_TOGGLE; then
            PER_DIRECTORY_HISTORY_TOGGLE='^G'
        fi
    fi

    # --- history file ---
    if [[ ! -d ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history ]]; then
        mkdir -p ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history
        [[ -f ${HOME}/.zsh_history ]] && mv ${HOME}/.zsh_history ${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history/history
    fi
    HISTFILE=${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-history/history

    # --- history size ---
    local _hist_size
    zstyle -s ':zdot:history' size _hist_size
    : ${_hist_size:=50000}
    HISTSIZE=${_hist_size}
    local _save_hist_size
    zstyle -s ':zdot:history' save-size _save_hist_size
    : ${_save_hist_size:=50000}
    SAVEHIST=${_save_hist_size}

    # --- shell options ---
    setopt SHARE_HISTORY
    setopt HIST_IGNORE_SPACE
    setopt HIST_REDUCE_BLANKS
}

# Register hook - requires XDG paths for history directory
zdot_simple_hook history
