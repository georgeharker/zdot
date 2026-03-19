# brew — Homebrew environment

Initialises Homebrew's `PATH` and environment variables on macOS. Guards
against running on non-macOS systems and skips silently if Homebrew is already
initialised (`$HOMEBREW_PREFIX` set).

## Requirements

- macOS only — silently skips on Linux/other platforms
- Homebrew installed at `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel)

## What it does

1. Sets `HOMEBREW_AUTO_UPDATE_SECS=3600`, `HOMEBREW_BAT=1`,
   `HOMEBREW_NO_ENV_HINTS=1`
2. Runs `brew shellenv` to add Homebrew's `bin/` and `sbin/` to `PATH` and
   set `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, etc.
3. Verifies that expected tools are present on `PATH` (warning only —
   does not abort)

## Configuration

Override the default tool list to verify:

```zsh
zstyle ':zdot:brew' verify-tools op eza gh tmux
```

The default list is: `op eza oh-my-posh gh tmux tailscale`

This zstyle is read **at module source time** (not in a configure hook), so it
must be set before `zdot_load_module brew` is called.

## Provides

- Phase: `brew-ready`
- Tools: whatever is in the `verify-tools` list (advertised to the hook
  dependency system so downstream hooks can declare `--requires-tool`)
