# apt — Debian/Ubuntu tool verification

Declares tool availability for Debian-based systems. Verifies that expected
apt-installed tools are present on `PATH` after system setup.

## Requirements

- Debian/Ubuntu only — silently skips on non-Debian platforms
- `xdg` and `env` modules must be loaded first

## What it does

Calls `zdot_verify_tools_zstyle` to check that expected tools are on `PATH`.
Issues a warning for each missing tool but does not abort. This makes missing
tool gaps visible at shell start rather than silently failing later.

## Configuration

Override the default tool list:

```zsh
zstyle ':zdot:apt' verify-tools op eza gh zoxide rg bat fd
```

The default list is: `op eza oh-my-posh gh tailscale zoxide rg bat fd`

This zstyle is read **at module source time** (not in a configure hook), so it
must be set before `zdot_load_module apt` is called.

## Provides

- Phase: `apt-ready`
- Tools: whatever is in the `verify-tools` list (advertised to the hook
  dependency system so downstream hooks can declare `--requires-tool`)
