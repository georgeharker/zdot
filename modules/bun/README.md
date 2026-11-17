# modules/bun — Bun Module

Wires [Bun](https://bun.com) into the shell: environment, the global-install
bin dir on `PATH`, and generated zsh completions. Bun itself comes from a tool
provider (brew/apt `verify-tools` / `optional-tools`, or the curl installer);
this module doesn't install it.

## Why there is no lazy loading

The `nodejs` module defers nvm because sourcing `nvm.sh` and running
`nvm use` costs 200–500 ms. Bun is a single static binary that needs no
per-shell activation, so there's nothing to defer. The module does two cheap
things at load: a `PATH` edit and a completion registration.

## PATH: the global bin dir

`bun add -g <pkg>` links executables into a bin dir that is **not** on `PATH`
by default (brew-installed bun puts nothing there). The module adds it,
resolving it the way `bun pm bin -g` does, but without spawning bun:

1. `zstyle ':zdot:bun' global-bin`, if set
2. `$BUN_INSTALL_BIN`
3. `$BUN_INSTALL/bin`
4. `$XDG_CACHE_HOME/.bun/bin`
5. `~/.bun/bin`

The dir is added even when it doesn't exist yet, so a package installed with
`bun add -g` mid-session can be run right away.

The dir is **appended** by default, so brew/system binaries win on a name
clash. nvm's `use` prepends its own bin dir later, so nvm-managed npm globals
also win over bun globals with the same name. Set `path-position prepend` if
you want bun globals to win.

> **Shebangs:** most npm packages ship `#!/usr/bin/env node` bins. Installing
> one with `bun add -g` doesn't change that, so it still needs a `node` on
> `PATH` at run time. Moving a tool from npm to bun only drops the nvm
> dependency if the tool runs under bun (`bun --bun`) or is a bun-native bin.
> Keep that in mind before removing a tool from `':zdot:nodejs' lazy-cmd`.

## Completions

`bun completions zsh` is registered with `zdot_register_completion_file`.
The output is cached in the zdot completions dir and regenerated when the bun
binary is newer. This replaces the OMZ `bun` plugin, which rewrites the file
in the background on every shell start.

## Configuration

| zstyle | Default | Purpose |
|---|---|---|
| `':zdot:bun' install-dir` | unset | Exported as `BUN_INSTALL` |
| `':zdot:bun' global-bin` | bun's resolution (above) | Dir added to `PATH` |
| `':zdot:bun' path-position` | `append` | `append` or `prepend` |
| `':zdot:bun' dns-ipv4` | `yes` | Export `BUN_DNS_USE_IPV4=1` |

Set these in a `bun-configure` group hook, which runs before `_bun_configure`
reads them:

```zsh
_my_bun_configure() {
    zstyle ':zdot:bun' path-position prepend
}
zdot_register_hook _my_bun_configure interactive noninteractive \
    --group bun-configure
```

## Update nagging

When the `update-nag` module points at a fork with the `bun` provider, bun
globals show up in the nag as `bun (global)`, controlled by
`zsh_pkg_update_nag_bun` (`all` / `off` / allowlist) in the plugin's
`config.zsh`. Upgrades run `bun add -g <pkg>@<version>`.

## Hooks

| Hook | Phase | Notes |
|---|---|---|
| `_bun_configure` | configure | Consumer of the `bun-configure` group |
| `_bun_load` | load | `--requires-optional-tool bun` (skipped if bun is absent); member of `completions-producers` |
