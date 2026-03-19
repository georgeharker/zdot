# dotfiler — dotfiler update checker and completions

Sources dotfiler's `check_update.zsh` and `completions.zsh` at interactive
shell start. Compiles them to `.zwc` bytecode for faster subsequent sourcing.

## Requirements

- `op` / `GH_TOKEN` — the update checker uses a GitHub token to check for
  new releases. This module requires `secrets-loaded` so that `GH_TOKEN` is
  available before the check runs.
- dotfiler scripts directory — see detection below.

## Scripts directory detection

The module locates dotfiler's scripts directory using this priority order:

1. `zstyle ':zdot:dotfiler' scripts-dir '/path/to/dotfiler'` — explicit override
2. `$XDG_DATA_HOME/dotfiler` — XDG conventional location
3. `~/.dotfiles/.nounpack/dotfiler` — conventional dotfiler repo layout

If none of these resolves, the module silently skips — no error.

This is the **same zstyle key** used by the zdot self-update system
(`core/update.zsh`), so setting it once configures both.

## Configuration

```zsh
# Explicit scripts dir (rarely needed — auto-detection covers most setups)
zstyle ':zdot:dotfiler' scripts-dir '/path/to/dotfiler'

# dotfiler update mode (set inside the module, override here if needed)
# zstyle ':dotfiler:update' mode auto   # default set by this module: prompt
```

## Provides

- Phase: `dotfiler-ready`

## Note on update integration

This module handles the **shell-start update check** (sourcing
`check_update.zsh`). The full dotfiler/zdot update lifecycle (pull, unpack,
symlink management) is handled separately by `core/dotfiler-hook.zsh` and
`core/update.zsh`. See [docs/quickstart-dotfiler.md](../../docs/quickstart-dotfiler.md).
