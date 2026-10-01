# brew — Homebrew environment

Initialises Homebrew's `PATH` and environment variables on macOS. Guards
against running on non-macOS systems and skips silently if Homebrew is already
initialised (`$HOMEBREW_PREFIX` set).

## Requirements

- macOS only — silently skips on Linux/other platforms
- Homebrew installed at `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel)

## Configuration

Tool verification is **config-driven** — the module states no list of its own
here. Two zstyles, both read at module source time (set them before
`zdot_load_module brew`, e.g. via `zdot_before_module`):

```zsh
zstyle ':zdot:brew' verify-tools   op eza oh-my-posh gh tmux tailscale
zstyle ':zdot:brew' optional-tools eza oh-my-posh gh tmux tailscale
```

- `verify-tools` is **mandatory**: if it is not configured at all, the hook
  fails with an error at shell start (an unconfigured manifest is a
  configuration error, not a silent default). Set it explicitly — even to
  `zstyle ':zdot:brew' verify-tools ''` to declare "no manifest tools" — on a
  working-but-bare machine.
- `optional-tools` is the subset of `verify-tools` whose absence is expected:
  those are verified **quietly** (verbose only) instead of warning. Unset it
  and nothing is quiet — every missing manifest tool warns. Consumers of an
  optional tool gate themselves with `--requires-optional-tool <tool>` and are
  skipped when the tool wasn't installed; keep essential tools (e.g. `op`)
  out of the optional list so a missing one still warns.
- Missing non-optional tools produce a warning only — verification never
  aborts the shell.

## Provides

- Phase: `brew-ready`
- Tools: the `verify-tools` list (or, at source time only, the module's
  fallback claim list when the zstyle is unset — see brew.zsh; advertised to
  the hook dependency system so downstream hooks can declare
  `--requires-tool` / `--requires-optional-tool`)
