# zstyle Configuration Reference

All `zstyle` options recognised by zdot, grouped by subsystem. Set these in
your `.zshrc` **before** sourcing `zdot.zsh` (or before the relevant module is
loaded) unless noted otherwise.

---

## Logging — `:zdot:logging`

Source: `core/logging.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `quiet` | bool | `false` | Suppress all non-error output. Equivalent to omitting `zdot_info`/`zdot_success` messages. |
| `verbose` | bool | `false` | Enable verbose output. Sets `ZDOT_VERBOSE=1`. |
| `verbose-noninteractive` | bool | `false` | Enable verbose output in non-interactive shells (normally suppressed even when `ZDOT_VERBOSE=1`). |

**Example:**
```zsh
zstyle ':zdot:logging' quiet   true   # silent startup
zstyle ':zdot:logging' verbose true   # debug startup
```

---

## Deferred progress — `:zdot:defer`

Source: `core/logging.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `progress` | bool | `false` | Show ephemeral progress indicators during deferred initialisation. |

---

## Cache — `:zdot:cache`

Source: `core/cache.zsh` · See also: [caching-implementation.md](caching-implementation.md)

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `true` | Enable or disable the bytecode/execution-plan cache. |
| `directory` | string | `$XDG_CACHE_HOME/zdot` | Override the cache root directory. |

**Example:**
```zsh
zstyle ':zdot:cache' enabled   false
zstyle ':zdot:cache' directory ~/.my-cache/zdot
```

---

## Modules — `:zdot:modules`

Source: `core/modules.zsh` · See also: [Module Search Path](../README.md#module-search-path)

| Key | Type | Default | Description |
|---|---|---|---|
| `search-path` | array | _(empty)_ | Ordered list of directories to search for modules, prepended before the built-in `modules/` dir. `~/.config/zdot-modules` is included automatically if it exists. |

**Example:**
```zsh
zstyle ':zdot:modules' search-path \
    "${XDG_CONFIG_HOME}/zsh/modules" \
    "${HOME}/.dotfiles/zsh-extra"
```

---

## Variant — `:zdot:variant`

Source: `core/ctx.zsh` · See also: [Variants](../README.md#variants)

| Key | Type | Default | Description |
|---|---|---|---|
| `name` | string | _(empty)_ | Active variant name. Overridden by `$ZDOT_VARIANT` env var; overridden by `zdot_detect_variant()` function if defined. |

**Example:**
```zsh
zstyle ':zdot:variant' name work
```

Priority order (highest first): `$ZDOT_VARIANT` → `zstyle ':zdot:variant' name` → `zdot_detect_variant()`.

---

## Plugins — `:zdot:plugins`

Source: `core/plugins.zsh`, `core/plugin-bundles/omz.zsh`, `core/plugin-bundles/pz.zsh`  
See also: [plugins.md](plugins.md), [plugin-implementation.md](plugin-implementation.md)

| Key | Type | Default | Description |
|---|---|---|---|
| `directory` | string | `$XDG_CACHE_HOME/zdot/plugins` | Override the plugin clone cache directory. |
| `compile` | bool | `true` | Compile plugins to `.zwc` bytecode after loading. |
| `defer` | bool | `false` | Clone and load `romkatv/zsh-defer` for deferred plugin loading. |
| `omz` | bool | `true` | Enable Oh-My-Zsh bundle support (clones `ohmyzsh/ohmyzsh`). |
| `pz` | bool | `false` | Enable Prezto bundle support (clones `sorin-ionescu/prezto`). |

**Example:**
```zsh
zstyle ':zdot:plugins' directory ~/.cache/myzsh/plugins
zstyle ':zdot:plugins' compile   false
zstyle ':zdot:plugins' omz       false   # opt out of OMZ
```

---

## Compinit — `:zdot:compinit`

Source: `core/compinit.zsh` · See also: [compinit.md](compinit.md)

| Key | Type | Default | Description |
|---|---|---|---|
| `skip-compaudit` | bool | `false` | Skip `compaudit` security check during `compinit`. Speeds up startup on trusted machines. |

**Example:**
```zsh
zstyle ':zdot:compinit' skip-compaudit true
```

---

## Self-update — `:zdot:update`

Source: `core/update.zsh`, `core/update-impl.zsh`  
See also: [implementation.md](implementation.md)

Self-update is **opt-in** — set `mode` to activate. All other keys are ignored
when `mode` is `disabled`.

| Key | Type | Default | Description |
|---|---|---|---|
| `mode` | string | `disabled` | Update mode: `disabled` \| `reminder` (print notice only) \| `prompt` (ask interactively) \| `auto` (update without asking). |
| `frequency` | integer | `3600` | Minimum seconds between update checks. |
| `destdir` | string | `$XDG_CONFIG_HOME/zdot` | Directory where the link-tree is unpacked (the home-side destination). |
| `link-tree` | bool | `true` | Run link-tree unpacking after a pull. Set `false` to skip symlink management. |
| `dotfiler-integration` | string | _(auto)_ | Force dotfiler integration on (`true`/`yes`/`on`/`1`) or off (`false`/`no`/`off`/`0`). Default: auto-detected from repo topology. |
| `in-tree-commit` | string | `none` | How to handle in-tree (non-submodule) commits: `none` \| `prompt` \| `auto`. |
| `subtree-remote` | string | _(empty)_ | `"remote branch"` string for `git subtree pull` (subtree topology only). |
| `subtree-url` | string | _(empty)_ | Remote URL override for subtree pulls. |

**Example:**
```zsh
zstyle ':zdot:update' mode      auto
zstyle ':zdot:update' frequency 7200   # check every 2 hours
```

---

## dotfiler integration — `:zdot:dotfiler`

Source: `core/update.zsh`, `core/update-impl.zsh`, `modules/dotfiler/dotfiler.zsh`  
See also: [dotfiler Integration](../README.md#dotfiler-integration)

| Key | Type | Default | Description |
|---|---|---|---|
| `scripts-dir` | string | _(auto-detected)_ | Path to the dotfiler scripts directory (containing `update_core.zsh` and `setup_core.zsh`). Auto-detected from parent repo or plugin cache if not set. |

Detection order (first match wins):
1. This `zstyle` value (if set and valid)
2. `$parent_repo/.nounpack/dotfiler/` (if zdot is inside a dotfiler-managed repo)
3. `$XDG_DATA_HOME/dotfiler/` (XDG data location)
4. `~/.dotfiles/.nounpack/dotfiler/` (conventional fallback)
5. Plugin cache (`$XDG_CACHE_HOME/zdot/plugins/georgeharker/dotfiler`) — cloned on demand

**Example:**
```zsh
zstyle ':zdot:dotfiler' scripts-dir ~/.dotfiles/.nounpack/dotfiler
```

---

## Module: autocompletion — `:zdot:autocompletion`

Source: `modules/autocompletion/autocompletion.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `fsh-theme` | string | _(built-in default)_ | Path to a `fast-syntax-highlighting` theme `.ini` file. |

---

## Module: fzf — `:zdot:fzf`

Source: `modules/fzf/fzf.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `theme` | string | _(built-in default)_ | Path to an fzf colour theme shell file. |

---

## Module: nodejs — `:zdot:nodejs`

Source: `modules/nodejs/nodejs.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `lazy-cmd` | array | `(node npm npx yarn pnpm)` | Commands that trigger lazy-loading of the Node.js version manager. |

**Example:**
```zsh
zstyle ':zdot:nodejs' lazy-cmd node npm npx corepack
```

---

## Module: secrets — `:zdot:secrets` / `:zdot:secrets:op`

Source: `modules/secrets/secrets.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `:zdot:secrets` `ssh-platforms` | array | _(OS-specific)_ | List of `$OSTYPE` glob patterns for which to set up SSH agent via 1Password. |
| `:zdot:secrets` `ssh-func` | string | _(empty)_ | Name of a function to call for custom SSH agent setup instead of the built-in logic. Called with the resolved SSH socket path. |
| `:zdot:secrets:op` `service-acct-vault` | string | _(empty)_ | 1Password vault name for service account credentials. |
| `:zdot:secrets:op` `api-vault` | string | _(empty)_ | 1Password vault name for API tokens. |
| `:zdot:secrets:op` `ssh-vault` | string | _(empty)_ | 1Password vault name for SSH keys. |
| `:zdot:secrets:op` `service-acct-grants` | array | _(empty)_ | List of grants to configure for the service account. |

---

## Module: venv — `:zdot:venv`

Source: `modules/venv/venv.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `python-version-macos` | string | _(auto)_ | Python interpreter path or version string to use on macOS. |
| `python-version-linux` | string | _(auto)_ | Python interpreter path or version string to use on Linux. |

**Example:**
```zsh
zstyle ':zdot:venv' python-version-macos '/opt/homebrew/bin/python3.13'
zstyle ':zdot:venv' python-version-linux  'cpython@3.13.0'
```

---

## Module: brew — `:zdot:brew`

Source: `modules/brew/brew.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `verify-tools` | array | `(op eza oh-my-posh gh tmux tailscale)` | List of tools whose presence is verified after brew init. Override to add or replace. |

---

## Module: apt — `:zdot:apt`

Source: `modules/apt/apt.zsh`

| Key | Type | Default | Description |
|---|---|---|---|
| `verify-tools` | array | `(op eza oh-my-posh gh tailscale zoxide rg bat fd)` | List of tools whose presence is verified after apt setup. Override to add or replace. |
