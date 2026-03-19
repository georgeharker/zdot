# fzf — fzf fuzzy finder integration

Loads the OMZ `fzf` plugin and `fzf-tab`, configures keybindings and
completion menu styles, and registers custom ZLE widgets for interactive
ripgrep/fd searches.

## Requirements

- `fzf` on `PATH`
- `rg` (ripgrep) and `fd` — for the ZLE search widgets
- `eza` — for zoxide directory preview in fzf-tab
- `plugins-cloned` and `omz-bundle-initialized`

## What it does

### fzf-tab

Replaces the default zsh completion menu with an fzf popup. Configured with:

- `tab:accept` binding (press Tab to confirm selection)
- `<` / `>` to switch between completion groups
- `use-fzf-default-opts yes` — respects your `FZF_DEFAULT_OPTS`
- zoxide directory preview via `eza -1 --color=always --icons`

### ZLE widgets

Two custom widgets are registered:

- **`fzf-rg`** — interactive ripgrep search; results open in `$EDITOR`
- **`fzf-fd`** — interactive file search via fd; result inserted at cursor

### OMZ fzf plugin

Provides `**` tab-expansion triggers and `Ctrl-T` / `Ctrl-R` / `Alt-C`
keybindings from the OMZ fzf plugin.

## Configuration

```zsh
# Path to an fzf colour theme shell file:
zstyle ':zdot:fzf' theme '/path/to/fzf-theme.sh'

# Disable theme:
zstyle ':zdot:fzf' theme ''
```

### fzf-tab zstyles

The module sets sensible defaults. Override any of these before the
`omz-configure` group runs:

```zsh
zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:*' fzf-bindings 'tab:accept'
zstyle ':fzf-tab:*' switch-group '<' '>'
```

## Provides

- Tool: `fzf`
