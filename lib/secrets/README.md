# lib/secrets — 1Password Secrets Module

Manages 1Password CLI (`op`) integration for shell sessions. Loads a
service-account token and injects secrets from a template into a per-user
cache, making them available as environment variables in both interactive
and noninteractive shells (e.g. tmux panes, editor terminals, scripts).

## Requirements

- `op` (1Password CLI) must be installed and on `$PATH`
- `$XDG_CONFIG_HOME` and `$XDG_CACHE_HOME` must be set (provided by
  `lib/xdg`, which this module depends on)

## How it works

### File layout

```
$XDG_CONFIG_HOME/secrets/
    op-secrets.zsh      # template: exports OP_SERVICE_ACCOUNT_TOKEN reference
    secrets.zsh         # template: exports arbitrary secrets via op:// URIs

$XDG_CACHE_HOME/secrets/
    $USER.op-secrets.zsh    # injected: live service account token
    $USER.secrets.zsh       # injected: live secret values
```

The `*.zsh` files under `$XDG_CONFIG_HOME/secrets/` are **templates** — they
contain `op://` secret references rather than plaintext values, and are safe to
keep in version control. `op inject` resolves them at runtime and writes the
results to the cache directory, which should not be committed.

### Startup sequence

On every shell start `_op_init` does the following in order:

1. Runs the `secrets-configure` group (user configuration hooks — see below)
2. If the cached `$USER.op-secrets.zsh` is missing or older than the template,
   calls `op_refresh` to rebuild it
3. Sources `$USER.op-secrets.zsh` to load `OP_SERVICE_ACCOUNT_TOKEN`; sets
   `_ZDOT_OP_ACTIVE=1` if the token is present
4. If active and the cached `$USER.secrets.zsh` is stale, calls
   `refresh_shell_secrets` to re-inject
5. Sources `$USER.secrets.zsh` to export secrets into the environment
6. Sets up `SSH_AUTH_SOCK` to point at the 1Password SSH agent (macOS only,
   skipped when in an SSH connection)

Interactive prompts (first-time setup, service account creation) only fire in
interactive shells. Noninteractive shells silently skip setup if no cache exists.

---

## Configuration

All configuration is done via `zstyle` from within a `secrets-configure` group
hook (see below). The following zstyles are read by `op_get_vault_config` inside
`op_refresh`:

| zstyle key | Default | Purpose |
|---|---|---|
| `':zdot:secrets:op' service-acct-vault` | `ServiceAcct` | Vault where per-host service account credentials are stored |
| `':zdot:secrets:op' api-vault` | `API` | Vault containing API keys / tokens |
| `':zdot:secrets:op' ssh-vault` | `SSHKeys` | Vault containing SSH keys |
| `':zdot:secrets:op' service-acct-grants` | `(API:read_items,write_items SSHKeys:read_items,write_items)` | Array of `vault:permissions` strings granted to newly created service accounts |
| `':zdot:secrets' ssh-platforms` | `(mac)` | Platform names or `$OSTYPE` globs; SSH agent setup only runs when at least one matches. Accepts `mac`, `linux`, `debian`, or raw globs like `darwin*` |
| `':zdot:secrets' ssh-func` | *(unset)* | Name of a function to call as an additional gate; setup only proceeds if it returns 0 |

The `service-acct-grants` default is derived from the resolved `api-vault` and
`ssh-vault` values, so overriding those two is usually sufficient.

---

## Providing your own configuration

The `secrets-configure` **hook group** is the canonical extension point. Any hook
registered into this group is guaranteed to run before `_op_init` executes, giving
you a window to set zstyles before vault names are read.

### Minimal example

```zsh
# In your user module, e.g. ~/.config/zsh/modules/my-secrets.zsh

_my_op_configure() {
    zstyle ':zdot:secrets:op' service-acct-vault 'Employee'
    zstyle ':zdot:secrets:op' api-vault          'Private'
    zstyle ':zdot:secrets:op' ssh-vault          'Private'
    # service-acct-grants defaults to:
    #   Private:read_items,write_items  (derived from api-vault)
    #   Private:read_items,write_items  (derived from ssh-vault)
    # which collapses to a single grant — that's fine, op deduplicates.
}

zdot_register_hook _my_op_configure interactive noninteractive \
    --group secrets-configure
```

### Full example — custom vaults and grant set

```zsh
_my_op_configure() {
    zstyle ':zdot:secrets:op' service-acct-vault 'Automation'
    zstyle ':zdot:secrets:op' api-vault          'Work-API'
    zstyle ':zdot:secrets:op' ssh-vault          'Work-SSH'
    # Explicit grants — override the derived default entirely
    zstyle ':zdot:secrets:op' service-acct-grants \
        'Work-API:read_items,write_items' \
        'Work-SSH:read_items'
}

zdot_register_hook _my_op_configure interactive noninteractive \
    --group secrets-configure
```

### Loading your module

Point zdot at your modules directory and load the module before calling
`zdot_init`:

```zsh
zstyle ':zdot:user-modules' path "${XDG_CONFIG_HOME}/zsh/modules"
zdot_load_module secrets              # built-in
zdot_load_user_module my-secrets      # your configure hook
zdot_init
```

Because `lib/secrets` declares `--requires-group secrets-configure`, zdot's
topological planner guarantees the group-end barrier (and therefore your hook)
completes before `_op_init` runs, regardless of module load order.

---

## Secrets template format

`$XDG_CONFIG_HOME/secrets/secrets.zsh` is a standard `op inject` template.
Any `op://` URI is resolved at inject time. Example:

```zsh
# $XDG_CONFIG_HOME/secrets/secrets.zsh
export GITHUB_TOKEN="op://Private/GitHub Token/credential"
export OPENAI_API_KEY="op://Work-API/OpenAI/api_key"
export ANTHROPIC_API_KEY="op://Work-API/Anthropic/api_key"
```

Run `refresh_shell_secrets` manually to force a re-inject without restarting
your shell.

---

## Public functions

All functions are autoloaded on first call.

| Function | Description |
|---|---|
| `op_refresh` | Rebuild the service account token cache. Interactive: may prompt to create/select account. |
| `refresh_shell_secrets` | Re-inject `secrets.zsh` template into cache and source the result. Requires `_ZDOT_OP_ACTIVE=1`. |
| `op_auth` | Interactively sign in to 1Password. Called by `op_refresh`; rarely needed directly. |
| `op_get_vault_config` | Populate caller-local `op_svc_vault`, `op_api_vault`, `op_ssh_vault`, `op_svc_grants` from zstyle. |
| `op_get_config_dir` | Print the `op` config directory (sudo-aware). |
| `op_get_config_args` | Print `--config <dir>` args for `op` invocations (one token per line). |

### Global state

| Variable | Values | Meaning |
|---|---|---|
| `_ZDOT_OP_ACTIVE` | `0` / `1` | Set to `1` when a service account token is loaded and working. Other modules gate on this before using `op`. |

---

## First-time interactive setup

On first login in an interactive shell, if no `op` config or service account
exists, `op_refresh` will:

1. Call `op_auth` — prompts to sign in to 1Password if needed. Choosing `c`
   (cancel) defers setup to the next login. Choosing `n` creates a `no_op`
   sentinel file and permanently skips setup on that machine.
2. Prompt whether to create a **new** service account or select an **existing**
   one from the configured `service-acct-vault`.
3. If creating: runs `op service-account create` with the grants from
   `service-acct-grants`, stores the credential in `service-acct-vault`, writes
   the `op://` reference to `$XDG_CONFIG_HOME/secrets/op-secrets.zsh`.
4. Runs `op inject` to materialise the token into the cache, then signs out of
   the interactive session (the service account takes over from here).

On every subsequent shell start the module simply sources the cached token —
no interactive prompts fire.

---

## SSH agent

`_setup_ssh_auth_sock` creates `~/.1password/agent.sock` as a symlink to the
1Password agent socket and sets `SSH_AUTH_SOCK`, letting `ssh` and any tool
that respects `SSH_AUTH_SOCK` authenticate via keys stored in 1Password without
a separate `ssh-agent`.

Two independent gates control whether this runs. Both must pass:

### Platform gate — `ssh-platforms`

An array of platform names or `$OSTYPE` glob patterns. Setup only proceeds when
at least one matches. Accepts friendly short names or raw globs:

| Name | Matches |
|---|---|
| `mac` | macOS (`$OSTYPE == darwin*`) |
| `linux` | Any Linux (`$OSTYPE == linux*`) |
| `debian` | Debian/Ubuntu (`$OSTYPE == linux*` + `/etc/debian_version` present) |
| `darwin*`, `linux-gnu*`, … | Raw `$OSTYPE` glob, matched with `${~pat}` |

Default is `(mac)` — macOS only.

```zsh
# Also enable on Linux desktops running 1Password
zstyle ':zdot:secrets' ssh-platforms mac linux

# Disable entirely (empty array — never matches)
zstyle ':zdot:secrets' ssh-platforms
```

### Predicate gate — `ssh-func`

An optional function name. When set, the function is called with no arguments
and **replaces** the built-in default condition. When not set, the built-in
default applies: skip setup when `$SSH_CONNECTION` is non-empty (i.e. the shell
was started over an SSH connection).

Use `ssh-func` when you need a condition that cannot be expressed as an `$OSTYPE`
pattern — for example, allowing the agent even over SSH, or gating on a specific
terminal multiplexer:

```zsh
# Allow agent setup even over SSH (replaces the default SSH_CONNECTION guard)
_my_ssh_agent_check() {
    return 0
}

# Or: only set up when not inside tmux
_my_ssh_agent_check() {
    [[ -z "$TMUX" ]]
}

_my_op_configure() {
    zstyle ':zdot:secrets' ssh-func '_my_ssh_agent_check'
}

zdot_register_hook _my_op_configure interactive noninteractive \
    --group secrets-configure
```

The function must be defined before `_op_init` runs (i.e. inside or before
your `secrets-configure` hook). If the named function does not exist at runtime
a warning is emitted and SSH agent setup is skipped.
