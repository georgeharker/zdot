#!/usr/bin/env zsh
# Key bindings module
# Centralizes all custom key bindings

_keybinds_init() {
    # Bind into the vi keymaps explicitly (and emacs, for completeness) rather
    # than the transient `main` link. `main` is repointed by `bindkey -v` when
    # vi-mode loads, so binding into bare `main` here would strand these in
    # whatever keymap happened to be active at the time. Binding per-keymap is
    # order-independent: viins/vicmd/emacs always exist, and a later `bindkey -v`
    # leaves them untouched.
    #
    # It also matters for correctness in vi insert mode: these are all
    # ESC-prefixed sequences. If e.g. `\eD` (Alt-Left) isn't bound in `viins`,
    # the leading ESC triggers `vi-cmd-mode` and the trailing `D` leaks into
    # `vicmd` (delete-to-EOL); `\eC` (Alt-Right) leaks `C` (change-to-EOL).
    local km
    for km in viins vicmd emacs; do
        # Word navigation (Alt-Left / Alt-Right in Ghostty: ESC D / ESC C)
        bindkey -M $km '\eC' forward-word
        bindkey -M $km '\eD' backward-word
        # mac fn-key navigation
        bindkey -M $km '\e[H' beginning-of-line
        bindkey -M $km '\e[F' end-of-line
        bindkey -M $km '\e[5~' history-search-backward
        bindkey -M $km '\e[6~' history-search-forward
        bindkey -M $km '\e[1;3A' history-search-backward
    done
}

# Register hook: requires plugins to be loaded and post-configured
# Keybinds only needed in interactive shells
zdot_simple_hook keybinds --no-requires --context interactive --requires-group keybinds-configure
