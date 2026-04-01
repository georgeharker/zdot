# Built-in Modules

zdot ships a set of built-in modules in `modules/`. Each module is a
self-contained directory with a main `.zsh` file and optional `functions/`
subdirectory.

User modules live separately (see [Module Search Path](../README.md#module-search-path))
and shadow built-in modules of the same name. Use `zdot module clone <name>` to
copy a built-in module to your user directory as a starting point.

---

## Dependency map

The rough loading order imposed by dependencies:

```
xdg  →  env, sudo, history, secrets
         secrets  →  dotfiler, local_rc, uv (optional)
         xdg      →  brew / apt
                   →  omp-prompt | starship-prompt | omz-prompt  (provides prompt-ready)
                   →  plugins     →  autocompletion, fzf, shell-extras, tmux, nodejs
                   →  venv        →  completions
                                  →  rust, bun, uv
```

---

## Module reference

---

### `xdg`

Foundation module. Sets all XDG Base Directory variables and defines platform
helper functions (`is-macos`, `is-debian`). Nearly every other module requires
`xdg-configured` — load this first.

| | |
|---|---|
| **Provides** | `xdg-configured` |
| **Requires** | — |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `env`

Sets core environment variables: locale, `EDITOR`, `PAGER`, tool config paths
(`RIPGREP_CONFIG_HOME`, etc.), and `$DEV` / `$WORK` directory exports.

| | |
|---|---|
| **Provides** | `env-configured` |
| **Requires** | — |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `sudo`

When running under `sudo`, reconfigures `REAL_HOME`, disables tmux auto-start,
and repoints XDG dirs and `ZSH_COMPDUMP` to the invoking user's home. No-op
in normal shells.

| | |
|---|---|
| **Provides** | — |
| **Requires** | — |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `history`

Configures zsh history: creates the XDG history directory (migrating
`~/.zsh_history` if it exists), sets `HISTFILE` and `SAVEHIST`, and
enables `share_history`. Optionally enables per-directory history via the
`jimhester/per-directory-history` plugin (enabled by default; opt out with
`zstyle ':zdot:history' per-dir false`).

| | |
|---|---|
| **Provides** | — |
| **Requires** | — |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Default | Description |
|---|---|---|
| `':zdot:history' size` | `50000` | `HISTSIZE` — maximum number of history entries in memory |
| `':zdot:history' save-size` | `50000` | `SAVEHIST` — maximum number of history entries saved to disk |
| `':zdot:history' per-dir` | *(enabled)* | Set to `false`, `no`, or `0` to disable per-directory history |

---

### `secrets`

Manages 1Password integration. Loads and caches service account tokens and
shell secrets; sets `SSH_AUTH_SOCK` to the 1Password agent socket. Interactive
shells may prompt for auth; non-interactive shells only consume an existing
cache.

| | |
|---|---|
| **Provides** | `secrets-loaded` |
| **Requires** | `xdg-configured`, tool `op` |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Description |
|---|---|
| `':zdot:secrets:op' service-acct-vault` | 1Password vault name for service account credentials |
| `':zdot:secrets:op' api-vault` | 1Password vault name for API keys |
| `':zdot:secrets:op' ssh-vault` | 1Password vault name for SSH keys |
| `':zdot:secrets:op' service-acct-grants` | Array of vault grant strings |
| `':zdot:secrets' ssh-platforms` | `$OSTYPE` glob patterns / friendly names where SSH agent is configured (default: `mac`) |
| `':zdot:secrets' ssh-func` | Function name replacing the built-in SSH connection guard |

---

### `brew`

Initializes Homebrew `PATH` and environment on macOS. Silently skips on
non-macOS systems. Verifies that expected Homebrew-managed tools are present
after init.

| | |
|---|---|
| **Provides** | `brew-ready` |
| **Requires** | — |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Default | Description |
|---|---|---|
| `':zdot:brew' verify-tools` | `op eza oh-my-posh gh tmux tailscale` | List of tools to verify are present |

---

### `apt`

Declares tool availability for Debian/Ubuntu systems. Verifies that expected
apt-installed tools are present.

| | |
|---|---|
| **Provides** | `apt-ready` |
| **Requires** | `xdg-configured`, `env-configured` |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Default | Description |
|---|---|---|
| `':zdot:apt' verify-tools` | `op eza oh-my-posh gh tailscale zoxide rg bat fd` | List of tools to verify are present |

---

### `plugins`

Bootstraps the plugin management system. Registers the OMZ `omz:lib` bundle
and sets the OMZ update mode. Must be loaded before any module that uses
`--auto-bundle` or `--load-plugins`.

| | |
|---|---|
| **Provides** | (group: `omz-configure`) |
| **Requires** | — |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `omp-prompt`

Initialises [oh-my-posh](https://ohmyposh.dev/) as the shell prompt. Provides
`prompt-ready`. Only one prompt module should be loaded at a time.

| | |
|---|---|
| **Provides** | `prompt-ready` |
| **Requires** | `xdg-configured`, tool `oh-my-posh` (optional), group `omp-prompt-configure` |
| **Context** | interactive only |

| zstyle | Default | Description |
|---|---|---|
| `':zdot:omp-prompt' theme` | `$XDG_CONFIG_HOME/oh-my-posh/theme.toml` | Path to the oh-my-posh theme file |

---

### `starship-prompt`

Initialises [Starship](https://starship.rs/) as the shell prompt. Provides
`prompt-ready`. Only one prompt module should be loaded at a time.

| | |
|---|---|
| **Provides** | `prompt-ready` |
| **Requires** | `xdg-configured`, tool `starship` (optional), group `starship-prompt-configure` |
| **Context** | interactive only |

| zstyle | Default | Description |
|---|---|---|
| `':zdot:starship-prompt' config` | Starship's own default (`$XDG_CONFIG_HOME/starship.toml`) | Path to config file; sets `$STARSHIP_CONFIG` |

---

### `omz-prompt`

Activates an oh-my-zsh theme as the shell prompt. Provides `prompt-ready`.
Requires the OMZ bundle to be loaded. Only one prompt module should be loaded
at a time.

| | |
|---|---|
| **Provides** | `prompt-ready` |
| **Requires** | `xdg-configured` (optional), group `omz-prompt-configure` |
| **Context** | interactive only |

| zstyle | Default | Description |
|---|---|---|
| `':zdot:omz-prompt' theme` | _(required)_ | OMZ theme name, e.g. `robbyrussell` or `agnoster` |

---

### `autocompletion`

Loads completion, suggestion, and syntax-highlighting plugins:
`fast-syntax-highlighting`, `zsh-autosuggestions`, `zsh-abbr`, and
`fzf-tab`. Runs `compinit` deferred after all plugins settle.

| | |
|---|---|
| **Provides** | `autocomplete-*` phases (via `zdot_define_module`) |
| **Requires** | `plugins-cloned`, `omz-bundle-initialized` |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Description |
|---|---|
| `':zdot:autocompletion' fsh-theme` | Path to a `fast-syntax-highlighting` `.ini` theme file; set to empty string to disable theming |

---

### `fzf`

Loads the OMZ `fzf` plugin and `fzf-tab`; configures keybindings and
completion styles; registers custom ZLE widgets for ripgrep/fd search.

| | |
|---|---|
| **Provides** | tool `fzf` |
| **Requires** | `plugins-cloned`, `omz-bundle-initialized` |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Description |
|---|---|
| `':zdot:fzf' theme` | Path to an fzf colour theme shell file (empty string disables) |

---

### `shell-extras`

Loads OMZ plugins for `git`, `eza`, and `ssh`; on Debian/Ubuntu also loads
the `debian` plugin. Configures `eza` defaults (dirs-first, icons, git-status).

| | |
|---|---|
| **Provides** | — |
| **Requires** | `plugins-cloned`, `omz-bundle-initialized` |
| **Context** | interactive + noninteractive |
| **zstyle** | `':omz:plugins:eza'` keys (`dirs-first`, `git-status`, `icons`) — default `yes` |

---

### `tmux`

Loads the OMZ `tmux` plugin. Auto-starts tmux on SSH connections unless
already inside a multiplexer or `~/.notmux` exists.

| | |
|---|---|
| **Provides** | — |
| **Requires** | (via auto-bundle) |
| **Context** | interactive only |
| **zstyle** | none |
| **Tools** | `tmux` |

---

### `nodejs`

Configures and loads the OMZ `nvm` and `npm` plugins with lazy loading.
Activates the default node version after shell init. Lazy loading is
disabled in non-interactive shells and inside Neovim.

| | |
|---|---|
| **Provides** | tool `nvm` |
| **Requires** | (via auto-bundle) |
| **Context** | interactive + noninteractive |

**zstyle options:**

| Key | Default | Description |
|---|---|---|
| `':zdot:nodejs' lazy-cmd` | `opencode mcp-hub copilot prettierd claude-code` | Commands that trigger lazy nvm load |

---

### `rust`

Sources `~/.cargo/env` to put Rust/Cargo binaries on `PATH`. Registers
`rustup` and `cargo` completions. Silently skips if `~/.cargo/env` is absent.

| | |
|---|---|
| **Provides** | `rust-ready` |
| **Requires** | — |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `bun`

Sets `BUN_DNS_USE_IPV4=1` and registers zsh completions for Bun.

| | |
|---|---|
| **Provides** | `bun-ready` |
| **Requires** | — |
| **Context** | interactive + noninteractive |
| **zstyle** | none |
| **Tools** | `bun` |

---

### `uv`

Sources `~/.local/bin/env` to put `uv` on `PATH`. Activates `~/.venv` if
present. Registers completions for `uv` and `uvx`. Optional dependency on
`secrets-loaded`.

| | |
|---|---|
| **Provides** | `uv-configured` |
| **Requires** | `secrets-loaded` (optional) |
| **Context** | interactive + noninteractive |
| **zstyle** | none |
| **Tools** | `uv`, `uvx` |

---

### `venv`

Configures the default Python interpreter (Homebrew on macOS, uv-managed
CPython on Linux). Sets `UV_NO_MANAGED_PYTHON`/`UV_MANAGED_PYTHON`. Defines
pypy venv aliases and activates `~/.venv` globally.

| | |
|---|---|
| **Provides** | `venv-configured`, `venv-ready` |
| **Requires** | `xdg-configured`, group `venv-configure`; optionally `secrets-loaded` |
| **Context** | interactive + noninteractive |

Set zstyle options in a hook registered into the `venv-configure` group to
avoid requiring top-of-`.zshrc` ordering:

```zsh
_my_venv_config() { zstyle ':zdot:venv' python-version-macos '/opt/homebrew/bin/python3.13' }
zdot_register_hook _my_venv_config interactive noninteractive --group venv-configure
```

**zstyle options:**

| Key | Default | Description |
|---|---|---|
| `':zdot:venv' python-version-macos` | `python3.14` | Python binary path on macOS |
| `':zdot:venv' python-version-linux` | `cpython@3.14.0` | Python version string for uv on Linux |

---

### `completions`

Two-phase completion management. Phase 1 adds per-module and global
completion dirs to `fpath` and registers file-based completions. Phase 2
runs all registered live completion generators (`gh`, `tailscale`, etc.).

| | |
|---|---|
| **Provides** | `completions-paths-ready`, `completions-ready` |
| **Requires** | Phase 1: `xdg-configured`; Phase 2: `completions-paths-ready`, `autocomplete-post-configured`, `rust-ready`, `bun-ready`, `uv-configured` |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `dotfiler`

Sources dotfiler's `check_update.zsh` and `completions.zsh` at shell start.
Requires `secrets-loaded` so that `GH_TOKEN` is available for the update
checker. Silently skips if the dotfiler scripts directory cannot be found.

| | |
|---|---|
| **Provides** | `dotfiler-ready` |
| **Requires** | `secrets-loaded` |
| **Context** | interactive only |

**zstyle options:**

| Key | Description |
|---|---|
| `':zdot:dotfiler' scripts-dir` | Explicit path to the dotfiler scripts directory. Auto-detected from parent repo, `$XDG_DATA_HOME/dotfiler`, or `~/.dotfiles/.nounpack/dotfiler` if not set. |

---

### `local_rc`

Sources `~/.zshrc_local` if it exists, allowing per-machine customisation
without touching the shared dotfiles repo.

| | |
|---|---|
| **Provides** | `local-overrides-loaded` |
| **Requires** | `secrets-loaded` (optional) |
| **Context** | interactive + noninteractive |
| **zstyle** | none |

---

### `keybinds`

Registers custom ZLE key bindings: word navigation, macOS fn-key home/end,
and history search forward/backward.

| | |
|---|---|
| **Provides** | — |
| **Requires** | — (no-requires) |
| **Context** | interactive only |
| **zstyle** | none |

---

## Excluded / legacy modules

| Module | Notes |
|---|---|
| `old-plugins` | Legacy antidote-based plugin loader. Superseded by the current plugin system. Do not load alongside `plugins`. |
| `test-debug` | Developer diagnostic module. Not for production use. |
