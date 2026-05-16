# autocompletion — completion, highlighting, and suggestion plugins

Loads and configures the shell's completion and input-enhancement plugin stack:

- **fast-syntax-highlighting** — syntax colouring as you type
- **zsh-autosuggestions** — fish-style inline suggestions
- **zsh-abbr** — shell abbreviations (expand on space like fish)
- **fast-abbr-highlighting** — highlights abbreviations inline
- **fzf-tab** (via the `fzf` module) — replaces the completion menu with fzf
- **zoxide** (OMZ plugin) — `z` directory jumper with fzf preview

## Requirements

- `plugins-cloned` — plugin repos must be cloned first
- `omz-bundle-initialized` — OMZ lib must be set up
- `fzf` tool on `PATH` (for fzf-tab)
- `zoxide` tool on `PATH`

## Plugin loading order

Plugins are loaded in a deferred dependency chain after OMZ plugins settle:

```
autocomplete-loaded
    → zsh-abbr          (abbr-ready)
    → fast-syntax-highlighting  (fsh-ready)
        → fast-abbr-highlighting  (fast-abbr-ready)
    → zsh-autosuggestions  (autosuggest-ready)
        → zsh-autosuggestions-abbreviations-strategy  (autosuggest-abbr-ready)
```

`compinit` runs deferred after all plugins have loaded (`autosuggest-abbr-ready`).

## Configuration

### fast-syntax-highlighting theme

```zsh
# Path to a .ini theme file (e.g. Tokyo Night):
zstyle ':zdot:autocompletion' fsh-theme "${XDG_CONFIG_HOME}/fast-syntax-highlighting/mytheme.ini"

# Disable theme loading entirely:
zstyle ':zdot:autocompletion' fsh-theme ''
```

Default: `$XDG_CONFIG_HOME/fast-syntax-highlighting/tokyonight.ini` (loaded
only if the file exists and is newer than the current theme marker).

### zsh-abbr abbreviations file

The abbreviations file defaults to
`$XDG_CONFIG_HOME/zsh-abbr/user-abbreviations`. Create and populate it:

```zsh
abbr add gs='git status'
abbr add gd='git diff'
```

### Autosuggestion strategy

The suggestion strategy is `match_prev_cmd abbreviations completion` — it
prefers commands that match the previous context, then abbreviation expansions,
then plain completion. Override by setting `ZSH_AUTOSUGGEST_STRATEGY` before
this module's configure phase runs.

If the `history` module is also loaded (with `per-dir` enabled — the default),
the `match_prev_cmd` slot is swapped for `contextual_match_prev_cmd`. That
strategy ships in `georgeharker/zsh-contextual-history` and behaves identically
to upstream `match_prev_cmd` when local-history mode is off; when local-history
mode is toggled on (via the `local-toggle-key` bind) it restricts suggestions
to commands this shell typed.

## Provides

Phases via `zdot_define_module`: `autocomplete-configured`, `autocomplete-loaded`,
`autocomplete-post-configured`
