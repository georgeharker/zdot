# modules/bun — Bun Module

Wires [Bun](https://bun.com) into the shell: XDG locations for its state, the
global-install bin dir on `PATH`, and generated zsh completions. Bun itself
comes from a tool provider (brew/apt `verify-tools` / `optional-tools`, or the
curl installer); this module doesn't install it.

## XDG layout

By default the module puts bun's state in XDG dirs:

| Variable | Default | Holds |
|---|---|---|
| `BUN_INSTALL` | `$XDG_DATA_HOME/bun` | global packages (`install/global`), their bins (`bin/`), a curl-installed `bun` |
| `BUN_INSTALL_CACHE_DIR` | `$XDG_CACHE_HOME/bun` | the package download cache. You can delete it. |

For each variable, the first of these that's set wins: the zstyle
(`install-dir` / `cache-dir`), then a value already exported (e.g. from
`.zshenv`), then the XDG default. `zstyle ':zdot:bun' xdg no` turns the
XDG defaults off and leaves bun's own resolution in place.

**Why it matters:** left alone, bun uses `~/.bun`, but when `XDG_CACHE_HOME`
is set (as the `xdg` module does) it uses `$XDG_CACHE_HOME/.bun` instead. That
puts your **global packages in a cache dir** that cache cleaners may wipe.

### Existing installs and migrating

If `$XDG_DATA_HOME/bun` doesn't exist yet but `~/.bun` or
`$XDG_CACHE_HOME/.bun` already has global packages
(`install/global/package.json`) or a `bin/bun`, the module keeps using that
dir, so existing globals don't vanish. An empty `install/global` doesn't count:
even a read-only `bun pm bin -g` creates one.

To migrate, move the whole dir and open a new shell:

```zsh
mv ~/.bun "$XDG_DATA_HOME/bun"     # or "$XDG_CACHE_HOME/.bun"
```

The links in `bin/` are relative (`../install/global/node_modules/...`), so
they keep working after the move. Don't move the dir if `BUN_INSTALL_BIN`
points outside it; reinstall the globals instead.

## Why there is no lazy loading

The `nodejs` module defers nvm because sourcing `nvm.sh` and running
`nvm use` costs 200–500 ms. Bun is a single static binary that needs no
per-shell activation, so there's nothing to defer. The module does two cheap
things at load: a `PATH` edit and a completion registration.

## PATH: the global bin dir

`bun add -g <pkg>` links executables into a bin dir that is **not** on `PATH`
by default (brew-installed bun puts nothing there). The module adds it,
resolving it the way `bun pm bin -g` does, but without spawning bun:

1. `$BUN_INSTALL_BIN` (the `global-bin` zstyle sets it)
2. `install.globalBinDir` in the global bunfig (see below)
3. `$BUN_INSTALL/bin`, which is `$XDG_DATA_HOME/bun/bin` by default
4. `$XDG_CACHE_HOME/.bun/bin` (only with `xdg no`)
5. `~/.bun/bin`

`global-bin` is **exported** as `BUN_INSTALL_BIN`, not just put on `PATH`, so
bun links globals into the same dir that `PATH` searches.

### Setting the bin dir in bunfig (recommended)

The zstyle only reaches bun processes that inherit the exported
`BUN_INSTALL_BIN`. bun reads `install.globalBinDir` from its global bunfig
itself, so it also applies to tools that spawn bun with a scrubbed
environment. The module asks bun (`bun pm bin -g`, about 4 ms) rather than
reading the file itself, so `PATH` and bun always agree:

```toml
# ~/.config/bun/bunfig.toml
[install]
globalBinDir = "~/.local/bin"
```

bun only reads the global bunfig as `$XDG_CONFIG_HOME/.bunfig.toml` (when
`XDG_CONFIG_HOME` is absolute, and then **only** that file) or
`~/.bunfig.toml`, and no env var can point it elsewhere. To keep the real file
in a `bun/` subdir, symlink `$XDG_CONFIG_HOME/.bunfig.toml` to it. On macOS,
processes launched outside a shell (GUI apps, launchd) don't get
`XDG_CONFIG_HOME`, so they look for `~/.bunfig.toml` instead. Without that
file they get bun's defaults. If the resulting bin dir is already on `PATH`
(as `~/.local/bin` is, via the `env` module), nothing is added.

A curl-installed `bun` in `$BUN_INSTALL/bin` goes on `PATH` in the
**configure** hook, not load. The load hook's `--requires-optional-tool bun`
check runs before load, so `bun` has to be findable by then.

The dir is added even when it doesn't exist yet, so a package installed with
`bun add -g` mid-session can be run right away.

The dir is **appended** by default, so brew/system binaries win on a name
clash. The nodejs module puts nvm's `current/bin` first, so nvm-managed npm
globals also win over bun globals with the same name. Set `path-position prepend` if
you want bun globals to win.

> **Shebangs:** most npm packages ship `#!/usr/bin/env node` bins. Installing
> one with `bun add -g` doesn't change that, so it still runs on whichever
> `node` comes first on `PATH`, unless the bunnify node shim sends it to bun
> (see below).

## Completions

`bun completions zsh` is registered with `zdot_register_completion_file`.
The output is cached in the zdot completions dir and regenerated when the bun
binary is newer. This replaces the OMZ `bun` plugin, which rewrites the file
in the background on every shell start.

## Configuration

| zstyle | Default | Purpose |
|---|---|---|
| `':zdot:bun' xdg` | `yes` | XDG defaults for `BUN_INSTALL` / `BUN_INSTALL_CACHE_DIR` |
| `':zdot:bun' install-dir` | `$XDG_DATA_HOME/bun` | Exported as `BUN_INSTALL` |
| `':zdot:bun' cache-dir` | `$XDG_CACHE_HOME/bun` | Exported as `BUN_INSTALL_CACHE_DIR` |
| `':zdot:bun' global-bin` | bunfig `globalBinDir`, else `$BUN_INSTALL/bin` | Exported as `BUN_INSTALL_BIN`; added to `PATH` |
| `':zdot:bun' path-position` | `append` | `append` or `prepend` |
| `':zdot:bun' dns-ipv4` | `yes` | Export `BUN_DNS_USE_IPV4=1` |
| `':zdot:bun' node-shim` | `no` | Run bun-installed tools on the bun runtime (see below) |
| `':zdot:bun' node-shim-exclude` | none | Bin names the node shim keeps on node |

Set these in a `bun-configure` group hook, which runs before `_bun_configure`
reads them:

```zsh
_my_bun_configure() {
    zstyle ':zdot:bun' path-position prepend
}
zdot_register_hook _my_bun_configure interactive noninteractive \
    --group bun-configure
```

## Running bun-installed tools on bun: the node shim

`bun add -g` keeps each tool's `#!/usr/bin/env node` shebang, so tools you
install with bun still **run on node**. With `node-shim` on, the module puts
`shims/` first on `PATH`. Its `node` script receives those shebangs:

- A script that belongs to bun's global install runs on **bun**, unless its
  name is in `node-shim-exclude`. The shim works this out from the script
  itself: bin links resolve into `<BUN_INSTALL>/install/global/node_modules/…`,
  and that root holds a `bun.lock`. Requiring `install/global` keeps a
  bun-managed project's own `node_modules/.bin` scripts on node.
- Every other `node` call (`node -v`, `node script.js`, node-shebang scripts
  elsewhere) is passed **unchanged** to the real node. The shim removes its own
  directory from `PATH` and lets zsh find `node`. The trimmed `PATH` is
  inherited, so a second copy of the shim (another zdot checkout) also removes
  itself instead of looping. Processes the real node starts no longer see the
  shim.

```zsh
zdot_before_module bun --cmd zstyle ':zdot:bun' node-shim yes
zdot_before_module bun --cmd zstyle ':zdot:bun' node-shim-exclude tsc prettierd
```

Details:

- **Staying in front of nvm.** The nodejs module puts nvm's `current/bin`
  first on `PATH` in its configure phase, and the bun module loads after it
  (`--after node-configured`). A later `nvm use`, including the one nvm runs
  when the lazy `nvm` first loads, puts nvm's bin dir first again. A
  `preexec` hook moves `shims/` back in front before each command.
- **Other processes.** Being first on `PATH` is the switch: any process
  whose `PATH` has `shims/` first gets the shim, and anything else gets plain
  node. The exclude list reaches the shim as an exported variable,
  `ZDOT_BUN_NODE_SHIM_EXCLUDE`, not the zstyle. So services that copy their
  environment from the installing shell need it passed through, for example
  un-bien's `service.env`. A service whose `PATH` was copied while the shim
  was on keeps using it until it's reinstalled.
- **bun flags.** `--config=/dev/null` stops bun loading a `bunfig.toml` from
  the current directory. Its `preload` would otherwise inject a project's code
  into the tool. There's no `--bun`, so a tool's own child processes that call
  `node` still get the real one.
- **Turning it off.** Set `node-shim no` (or remove it). The next shell drops
  `shims/` from `PATH` and unsets the exclude variable.

## Helper commands: bun-as-npm

`bin/` holds commands that support bun but don't shadow anything. It's
appended to `PATH` whenever the module loads, whether or not the shim is on.

`bun-as-npm` is an `npmCommand` for pi (`["bun-as-npm", "--", "bun"]`). It
passes everything to bun except `npm view`, which becomes `bun pm view`. There
is deliberately no `npm` shim: a bun-backed `npm` first on `PATH` would catch
every `npm` call, including projects with a `package-lock.json` and `npm
publish`.

## Update nagging

When the `update-nag` module points at a fork with the `bun` provider, bun
globals show up in the nag as `bun (global)`, controlled by
`zsh_pkg_update_nag_bun` (`all` / `off` / allowlist) in the plugin's
`config.zsh`. Upgrades run `bun add -g <pkg>@<version>`.

## Tests

`zsh -f tests/test_bun.zsh`: dir resolution, legacy fallback, zstyle/env
precedence, PATH placement, the node shim (PATH order, nvm reordering, runtime
routing through `shims/node`) and the helper dir. Each case runs in a
throwaway `HOME`; cases needing the real bun or node are skipped without them.

## Hooks

| Hook | Phase | Notes |
|---|---|---|
| `_bun_configure` | configure | Consumer of the `bun-configure` group |
| `_bun_load` | load | `--requires-optional-tool bun` (skipped if bun is absent); member of `completions-producers` |
