# fzf-tab configuration
# Source after XDG setup, before plugin loading

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
