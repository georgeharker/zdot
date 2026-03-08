# Module Improvements — Genericity Analysis

## Objective

Assess which `lib/` modules are safe for third-party reuse and which contain
personal configuration, with a view to making this a properly generic, publishable
framework where personal overrides live in a user-controlled directory rather than
in the main `lib/` tree.

---

## Module Classification

### Fully Generic — Reusable As-Is

| Module | Notes |
|---|---|
| `lib/xdg` | Pure XDG standard directory setup. The root dependency for almost every other module. |
| `lib/shell` | History config using XDG paths only. |
| `lib/keybinds` | Pure key bindings, nothing personal. |
| `lib/completions` | Completion path/runner scaffolding. Tool list (`gh`, `tailscale`, `sharedserver`) is opinionated but not personal. |
| `lib/rust` | Sources `~/.cargo/env`, registers `rustup`/`cargo` completions. Fully standard. |
| `lib/bun` | Sources bun env, registers completion. Fully standard. |
| `lib/uv` | Sources uv env, registers completions. Fully standard. |
| `lib/prompt` | Generic — reads oh-my-posh config via XDG. |
| `lib/tmux` | Loads OMZ tmux plugin. No personal config. |
| `lib/ssh` | Manages tmux autostart on SSH connections. No personal data. |
| `lib/sudo` | Adjusts XDG dirs when running as sudo user. Generic. |
| `lib/plugins` | Framework plugin management + OMZ init. Generic. |
| `lib/local_rc` | Sources `~/.zshrc_local` — explicitly the personal override escape hatch. |
| `lib/brew` | Homebrew init + tool verification. Opinionated tool list but not personal. |
| `lib/apt` | Debian equivalent of brew. Same situation. |

---

### Mostly Generic — Minor Personal Content

#### `lib/fzf`

Good shape overall. Two issues:

- **Tokyo Night theme path** hardcoded — should be a `zstyle` or just absent from
  the framework (theme config belongs in user overrides).
- **`cx` alias preview** (`zstyle ':fzf-tab:complete:cx:*'`) depends on the
  `ZOXIDE_CMD_OVERRIDE=cz` set in `lib/env`. If a user doesn't set that override,
  the fzf-tab preview rule is targeting a command they may not have. Should be
  conditional or moved to the user module.

#### `lib/autocompletion`

- **Abbr file path** hardcoded to `${XDG_CONFIG_HOME}/zsh-abbr/user-abbreviations` —
  this is actually the `zsh-abbr` default so it's fine.
- **FSH theme path** (`${XDG_CONFIG_HOME}/fast-syntax-highlighting/tokyonight.ini`)
  is personal aesthetic. Should be configurable via zstyle or removed.

#### `lib/shell-extras`

Sets eza zstyles unconditionally in `_shell_extras_configure`:

```zsh
zstyle ':omz:plugins:eza' 'dirs-first' yes
zstyle ':omz:plugins:eza' 'git-status' yes
zstyle ':omz:plugins:eza' 'icons'      yes
```

These fire before user config has a chance to override them (configure hooks run
early). A reuser gets these preferences silently. Should either use
`zstyle -T` (truthy with user override) or read from zstyle rather than set it.

#### `lib/nodejs`

All generic except:

```zsh
zstyle ':omz:plugins:nvm' lazy-cmd opencode mcp-hub copilot prettierd claude-code
```

This list of commands that trigger nvm loading is personal. Should move to user
config or be read from a zstyle so each user can supply their own list.

#### `lib/aliases`

Single alias (`ytdl`) that is personal. Entire module is personal preference.
Move to user overrides.

---

### Not Generic — Contains Personal Config

#### `lib/env`

Multiple hardcoded personal values:

```zsh
export DEFAULT_USER=geohar
export DEVDIR="${HOME}/Development"
export DEPLOYDIR="${HOME}/Deployments"
export EXTDEVDIR="${DEVDIR}/ext"   # or "${HOME}/ext" on Linux
export BASIC_MEMORY_HOME="${HOME}/basic-memory"
export BASIC_MEMORY_CONFIG_DIR=...
```

Also enforces specific tool choices (`nvim` as `$EDITOR`, `bat` theme `tokyonight_night`,
specific ripgrep config path). A reuser inherits all of these.

**Fix:** Slim `lib/env` down to truly universal exports (`LANG`, `LC_ALL`, `PAGER`
pattern, `TMPDIR`). Move personal paths and tool opinions to a user module.

#### `lib/venv`

Python version pinned to 3.14 on both platforms. Personal convention aliases
(`npvenv`, `rpvenv`, `apvenv`) with `.pypyvenv` path. Move to user overrides.

#### `lib/dotfiler`

Hardcodes `$HOME/.dotfiles/.nounpack/dotfiler` — the author's personal dotfiles
repo layout. The dotfiler *pattern* (update checker + completions sourced from a
directory) is generic; the path is not.

**Fix:** Read path from `zstyle ':zdot:dotfiler' scripts-dir` (this zstyle already
exists in `core/update.zsh`) and make the module a no-op if it is unset.

#### `lib/secrets`

See dedicated section below.

#### `lib/mcp`

Entirely personal — functions manage the author's Gmail accounts and GCP OAuth
credentials stored in their 1Password vault. Not extractable without a complete
rewrite. Move to user overrides.

---

## Making `lib/secrets` Generic

The secrets module is architecturally sound: `op inject` as a pattern for
materialising secrets from templates into a cache is a legitimate generic mechanism.
The personal coupling is in the vault names used during service account setup.

### Current Hardcoded Vault Names (in `op_refresh`)

```zsh
# Service account creation
op service-account create "$host_service_account" \
    --vault API:read_items,write_items \
    --vault SSHKeys:read_items,write_items

# Storing the service account credential
op item create --vault ServiceAcct ...

# Listing existing accounts
op item list --vault ServiceAcct

# Template references
op://ServiceAcct/${host_service_account}/credential
op://API/...
op://SSHKeys/...
```

### Proposed zstyle API

```zsh
# Vault containing service account credentials
zstyle ':zdot:secrets:op' service-acct-vault 'ServiceAcct'

# Vault for API keys / tokens
zstyle ':zdot:secrets:op' api-vault 'API'

# Vault for SSH keys
zstyle ':zdot:secrets:op' ssh-vault 'SSHKeys'

# Vault access grants when creating new service accounts
# (space-separated list of "vault:permissions" pairs)
zstyle ':zdot:secrets:op' service-acct-grants \
    'API:read_items,write_items' \
    'SSHKeys:read_items,write_items'
```

`op_refresh` would read these at runtime:

```zsh
local svc_vault api_vault ssh_vault
zstyle -s ':zdot:secrets:op' service-acct-vault svc_vault || svc_vault='Employee'
zstyle -s ':zdot:secrets:op' api-vault          api_vault || api_vault='Private'
zstyle -s ':zdot:secrets:op' ssh-vault          ssh_vault || ssh_vault='Private'
```

The SSH agent setup in `_setup_ssh_auth_sock` is already generic (no vault
references); it just needs the macOS path to remain as-is since that is a
1Password-mandated location.

---

## Proposed Repository Structure for Publication

```
zdot/
  core/          # framework internals — fully generic, unchanged
  lib/           # generic built-in modules — no personal config
  examples/      # reference implementations for personal patterns
    env/
      env.zsh    # annotated example with DEFAULT_USER etc.
    secrets/
      secrets.zsh     # example op-secrets.zsh template
      mcpservers.json # example MCP config template
    mcp/
      mcp.zsh    # example Google/Gmail integration
    dotfiler/
      dotfiler.zsh
    aliases/
      aliases.zsh
  docs/
  ...
```

Users point `zstyle ':zdot:user-modules' path` at their own directory and copy/adapt
from `examples/` as needed.

---

## Action Items — Module Checklist

### Fully generic — no action needed

- [x] `lib/xdg`
- [x] `lib/shell`
- [x] `lib/keybinds`
- [x] `lib/completions` *(tool list is opinionated but not personal)*
- [x] `lib/rust`
- [x] `lib/bun`
- [x] `lib/uv`
- [x] `lib/prompt`
- [x] `lib/tmux`
- [x] `lib/ssh`
- [x] `lib/sudo`
- [x] `lib/plugins`
- [x] `lib/local_rc`
- [x] `lib/brew`
- [x] `lib/apt`

---

### Needs work

- [x] **`lib/secrets`**: Vault names replaced with `zstyle` reads via new
  `op_get_vault_config` helper. `secrets-configure` hook group added so user config
  hooks run before `_op_init`. SSH agent setup conditionalised with
  `':zdot:secrets' ssh-platforms` (OSTYPE glob array, default `darwin*`) and
  `':zdot:secrets' ssh-func` (optional predicate). See `lib/secrets/README.md`.

- [ ] **`lib/fzf`**: Make Tokyo Night theme path a zstyle or remove entirely. Make
  `cx` preview conditional on `ZOXIDE_CMD_OVERRIDE` being set.

- [ ] **`lib/autocompletion`**: Make FSH theme path
  (`fast-syntax-highlighting/tokyonight.ini`) a zstyle or remove from framework.

- [ ] **`lib/shell-extras`**: Convert unconditional `zstyle` sets to conditional
  (`zstyle -T` pattern or check-then-set) so user-set values take priority.

- [x] **`lib/nodejs`**: `lazy-cmd` list read from `zstyle ':zdot:nodejs' lazy-cmd`
  with built-in default `(opencode mcp-hub copilot prettierd claude-code)`.
  `node-configure` group hook available for user overrides. See `lib/nodejs/README.md`.

- [ ] **`lib/env`**: Strip personal exports. Move `DEFAULT_USER`, `DEVDIR`,
  `DEPLOYDIR`, `EXTDEVDIR`, `BASIC_MEMORY_*`, personal tool preferences to an
  example user module. Keep `LANG`, `LC_ALL`, `PAGER`, `TMPDIR`, `EDITOR`.

- [x] **`lib/venv`**: Python version reads from `zstyle ':zdot:venv' python-version-macos`
  and `':zdot:venv' python-version-linux`, defaulting to Homebrew `python3.14` and
  `cpython@3.14.0` respectively. Rationale for Homebrew Python on macOS (dyld / native
  lib linkage) documented in `lib/venv/README.md`. Aliases and functions retained as-is.

- [x] **`lib/dotfiler`**: Scripts dir resolved via `zstyle ':zdot:dotfiler' scripts-dir`
  (same key as `core/update.zsh`), falling back to `$XDG_DATA_HOME/dotfiler` then
  `$HOME/.dotfiles/.nounpack/dotfiler`. Module is a silent no-op when none resolve.

- [ ] **`lib/aliases`**: Move `ytdl` alias to example user module. Module can then
  be a no-op stub or removed.

- [ ] **`lib/mcp`**: Move entirely to `examples/mcp/`. Not frameworkable without
  complete rewrite.

---

### Infrastructure

- [ ] **Create `examples/` directory** with annotated versions of personal modules.
- [ ] **Update top-level README** to document user-module override pattern and the
  `':zdot:user-modules' path` zstyle.
