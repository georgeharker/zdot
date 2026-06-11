# Using Plugins

How to load third-party zsh plugins and configure the modules zdot ships.
This is the consumer's guide -- nothing here requires writing a module. When
you outgrow it, the [Module Writer's Guide](module-guide.md) is the next step.

---

- [The plugin lifecycle](#the-plugin-lifecycle)
- [Declaring plugins](#declaring-plugins)
- [Oh-My-Zsh plugins](#oh-my-zsh-plugins)
- [Prezto modules](#prezto-modules)
- [Configuring shipped modules](#configuring-shipped-modules)
- [Keeping plugins updated](#keeping-plugins-updated)
- [Cache locations](#cache-locations)
- [Troubleshooting](#troubleshooting)

---

## The plugin lifecycle

The plugin system works in three phases:

1. **Declaration** -- plugins are declared with `zdot_use_plugin`, either by
   modules you load or directly in your `.zshrc`
2. **Clone** -- `zdot_init` clones everything declared to the cache on first
   shell startup (and emits the `plugins-cloned` phase)
3. **Load** -- plugins are sourced eagerly, on a hook, or deferred until
   after the first prompt

Load the `plugins` module to bootstrap the system (it also registers the
background plugin-update reminder):

```zsh
zdot_load_module plugins
```

## Declaring plugins

```zsh
zdot_use_plugin <spec> [subcommand] [flags...]
```

Plugin specs:

| Format | Example | Description |
|--------|---------|-------------|
| GitHub repo | `Aloxaf/fzf-tab` | Cloned from GitHub |
| Pinned version | `user/repo@v1.0.0` | Specific tag/branch |
| OMZ plugin | `omz:plugins/git` | From the Oh-My-Zsh bundle |
| OMZ library | `omz:lib` | OMZ's lib/ files (lazy-loaded via stubs) |
| Prezto module | `pz:modules/git` | From the Prezto bundle |

Subcommands control *when* the plugin loads:

```zsh
zdot_use_plugin Aloxaf/fzf-tab               # declare; loaded in the plugins-cloned phase
zdot_use_plugin omz:plugins/git hook \
  --requires plugins-cloned                   # eager load via a registered hook
zdot_use_plugin zsh-users/zsh-autosuggestions defer \
  --name autosuggestions                      # deferred: load after the first prompt
zdot_use_plugin some/heavy-prompt defer-prompt  # deferred + prompt refresh after load
```

`hook`/`defer` accept `--name`, `--provides`, `--requires`, `--config <fn>`,
`--context`, and group flags so a plugin can participate in the dependency
graph like any hook -- see
[`zdot_use_plugin` in the API reference](api-reference.md#zdot_use_plugin)
for the full flag table.

> **Removed forms:** the old `zdot_use_defer`, `zdot_use_fpath`, and
> `zdot_use_path` functions no longer exist. Use
> `zdot_use_plugin <spec> defer` for deferred loading; for fpath-only or
> path-only consumption, declare the plugin and use
> [`zdot_add_fpath`](api-reference.md#zdot_add_fpath) /
> [`zdot_plugin_path`](api-reference.md#zdot_plugin_path) in a hook.

Declarations made in your `.zshrc` must appear **before** `zdot_init`, which
performs the clone pass.

## Oh-My-Zsh plugins

Access Oh-My-Zsh plugins with the `omz:` prefix:

```zsh
zdot_use_plugin omz:plugins/git
zdot_use_plugin omz:plugins/docker
zdot_use_plugin omz:plugins/tmux
```

The OMZ repo is cloned once and shared by all `omz:` specs. The shipped `omz`
module declares `omz:lib` (OMZ's library files, lazy-loaded via function
stubs) and registers OMZ in the update flow -- load it alongside `plugins`
when OMZ is your bundle:

```zsh
zdot_load_module plugins
zdot_load_module omz
```

To opt out of OMZ support entirely (skips the clone):

```zsh
zstyle ':zdot:plugins' omz false
```

To use an OMZ theme as your prompt, load the `omz-prompt` module and pick a
theme (see the [module catalog](modules.md#omz-prompt)):

```zsh
zdot_load_module omz-prompt
zstyle ':zdot:omz-prompt' theme robbyrussell
```

Several shipped modules are thin wrappers around OMZ plugins with the
dependency wiring done for you -- `nodejs` (nvm/npm with lazy loading),
`fzf`, `tmux`, `shell-extras` (git, eza, ssh). Prefer loading those over
declaring the raw `omz:` specs yourself.

## Prezto modules

Prezto support is **off by default**. Enable the bundle, then declare modules
with the `pz:` prefix or the convenience wrapper:

```zsh
zstyle ':zdot:plugins' pz true        # enable the Prezto bundle

zdot_use_plugin pz:modules/git
zdot_use_pz syntax-highlighting       # same as zdot_use_plugin pz:modules/syntax-highlighting
zdot_use_pz autosuggestions
```

Prezto is then cloned automatically (with submodules) on first startup. A
minimal `.zpreztorc` stub is created at `${ZDOTDIR:-$HOME}/.zpreztorc` if none
exists, so Prezto does not auto-load modules -- zdot handles module loading
exclusively via the `pz:` specs you declare.

## Configuring shipped modules

Most shipped modules are tuned with `zstyle` -- set values in `.zshrc` before
`zdot_init`:

```zsh
zstyle ':zdot:history' size 100000
zstyle ':zdot:nodejs'  lazy-cmd node npm npx corepack
zstyle ':zdot:brew'    verify-tools op fd ripgrep
zstyle ':omz:plugins:nvm' lazy yes
```

Two references cover the options:

- [Module catalog](modules.md) -- what each module does, provides, requires,
  and its zstyle keys
- [zstyle reference](zstyle-reference.md) -- every option, grouped by
  subsystem

Modules read most styles when their hooks run, so plain `zstyle` lines
anywhere before `zdot_init` work. A few values are read at module *parse*
time (noted in the catalog) -- set those before the `zdot_load_module` line,
or use a [`zdot_before_module`](api-reference.md#zdot_before_module)
callback. For grouping several settings, conditional logic, or running code
*before a module's init*, the configure-group mechanism is covered in
[User Extension Points](module-guide.md#user-extension-points).

## Keeping plugins updated

```zsh
zdot plugin list                      # all declared plugins
zdot plugin list --loaded             # loaded this session
zdot plugin list --installed          # present in the cache
zdot plugin check-updates             # report what's behind, change nothing
zdot plugin update                    # update everything
zdot plugin update Aloxaf/fzf-tab     # update one plugin
zdot plugin clean --dry-run           # show stale plugin directories
zdot plugin clean --remove-unused     # remove undeclared plugin clones
zdot plugin reclone                   # delete and re-clone everything
```

The `plugins` module also ships a background update reminder that scans every
git-backed plugin and bundle repo:

```zsh
zstyle ':zdot:plugin-update' mode      prompt   # disabled | reminder | prompt
zstyle ':zdot:plugin-update' frequency 14400    # seconds between scans
```

`reminder` prints a summary; `prompt` asks Y/n to fast-forward.

## Cache locations

Everything lives under `${XDG_CACHE_HOME:-~/.cache}/zdot/`:

| Path | Purpose |
|------|---------|
| `plugins/<org>/<repo>` | Cloned plugin repositories |
| `plugins/ohmyzsh/ohmyzsh` | The shared OMZ clone |
| `completions/` | Generated completion files |
| `plans/` | Cached execution plans |

Relocate the plugin cache with:

```zsh
zstyle ':zdot:plugins' directory /path/to/cache
```

## Troubleshooting

**A plugin didn't load.** Check the three phases in order: declared
(`zdot plugin list --declared`), on disk (`zdot plugin list --installed`),
loaded (`zdot plugin list --loaded`). A declared-but-not-installed plugin
usually means `zdot_init` hasn't run since the declaration was added.

**Interactive-only plugins in scripts.** Modules like `fzf` exit early in
non-interactive shells -- this is intentional (fzf requires zle).

**Completions aren't working.**

1. Check the compdump exists: `ls ${ZSH_COMPDUMP:-~/.zcompdump}*`
2. Check fpath includes the plugin: `print -l $fpath`
3. Force a refresh: `zdot completion refresh --force`, or
   `_ZDOT_FORCE_COMPDUMP_REFRESH=1 zsh` for a full compinit pass
   (see [compinit.md](compinit.md))
