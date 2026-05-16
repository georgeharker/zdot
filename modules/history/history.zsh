#!/usr/bin/env zsh
# Shell configuration module
# History settings and shell options

# zstyle ':zdot:history' size           <n>     # HISTSIZE (default: 50000)
# zstyle ':zdot:history' save-size      <n>     # SAVEHIST (default: 100000)
# zstyle ':zdot:history' per-dir        true    # set to false/no/0 to disable per-directory history
# zstyle ':zdot:history' start-global   false   # set to trueyes/no to start per-directory history local
# zstyle ':zdot:history' per-dir-key    '^G'    # set key to toggle global
# zstyle ':zdot:history' fzf-ctrl-r     true    # default follows whether 'fzf' module is loaded; set explicitly to override
# zstyle ':zdot:history' use-module     true    # set to false/no/0 to disable contextual-history zsh module
# zstyle ':zdot:history' local-toggle-key '^X^L'  # set key to walk local history

# Conditionally declare per-directory-history plugin only when it is enabled.
# We must do this at module-load time (before the hook runs) so that
# zdot_load_plugin can find it in the declared-plugin registry.
if zstyle -T ':zdot:history' per-dir; then
    zdot_use_plugin georgeharker/zsh-contextual-history
fi

_history_init() {
    # --- optional per-directory history ---
    if zstyle -T ':zdot:history' per-dir; then
      zstyle ':contextual-history:*' history-base "${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-context-history/"
        if zstyle -T ':zdot:history' start-global; then
          zstyle ':contextual-history:*' start-with-global true
        else
          zstyle ':contextual-history:*' start-with-global false
      fi
      zstyle ':contextual-history:*' group-by .git .histbase
      # zstyle ':contextual-history:*' refresh-on-nav false
      # zstyle ':contextual-history:*' debug true
      if ! zstyle -s ':zdot:history' per-dir-key _ch_toggle; then
          _ch_toggle='^G'
      fi
      zstyle ':contextual-history:*' toggle-key "$_ch_toggle"
      unset _ch_toggle

      # fzf-ctrl-r: if user set it explicitly, honour that; otherwise mirror the fzf module.
      local _ch_fzf
      if ! zstyle -s ':zdot:history' fzf-ctrl-r _ch_fzf; then
          if zdot_module_loaded fzf; then
              _ch_fzf=true
          else
              _ch_fzf=false
          fi
      fi
      zstyle ':contextual-history:*' fzf-bind-ctrl-r "$_ch_fzf"
      unset _ch_fzf

      if zstyle -T ':zdot:history' use-module; then
          zstyle ':contextual-history:*' use-module true
      else
          zstyle ':contextual-history:*' use-module false
      fi

      local _ch_local_toggle
      if ! zstyle -s ':zdot:history' local-toggle-key _ch_local_toggle; then
          _ch_local_toggle='^X^L'
      fi
      zstyle ':contextual-history:*' local-toggle-key "$_ch_local_toggle"
      unset _ch_local_toggle

      zdot_load_plugin georgeharker/zsh-contextual-history
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
