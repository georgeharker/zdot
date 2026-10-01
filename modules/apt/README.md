# apt — Debian/Ubuntu tool verification

Declares tool availability for Debian-based systems. Verifies that expected
apt-installed tools are present on `PATH` after system setup.

## Requirements

- Debian/Ubuntu only — silently skips on non-Debian platforms
- `xdg` and `env` modules must be loaded first

## What it does

Calls `zdot_verify_tools_zstyle` to check the configured manifest against
`PATH` — see the brew module's README for the full config contract
(`verify-tools` mandatory, `optional-tools` quiet subset, missing tools warn
but never abort).

## Configuration

```zsh
zstyle ':zdot:apt' verify-tools   op eza oh-my-posh gh tailscale zoxide rg bat fd
zstyle ':zdot:apt' optional-tools eza oh-my-posh gh tailscale zoxide rg bat fd
```

- `verify-tools` is mandatory — unconfigured is a startup ERROR.
- `optional-tools` demotes a miss to verbose-only; unset = nothing quiet.

This zstyle is read **at module source time** (not in a configure hook), so it
must be set before `zdot_load_module apt` is called.

## Provides

- Phase: `apt-ready`
- Tools: whatever is in the `verify-tools` list (advertised to the hook
  dependency system so downstream hooks can declare `--requires-tool`)
