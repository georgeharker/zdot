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

Auth mode is resolved from `zstyle ':zdot:secrets:op' mode`:
`service-account` (default), `login` or `lazy-login`.

**Service-account mode** — `_op_init` does the following in order:

1. Runs the `secrets-configure` group (user configuration hooks — see below)
2. If the cached `$USER.op-secrets.zsh` is missing or older than the template,
   calls `op_identity` to rebuild it
3. Sources `$USER.op-secrets.zsh` to load `OP_SERVICE_ACCOUNT_TOKEN`; sets
   `_ZDOT_OP_ACTIVE=1` if the token is present (or `op whoami` works)
4. If active and the cached `$USER.secrets.zsh` is older than its template,
   calls `refresh_shell_secrets` to re-inject
5. Sources `$USER.secrets.zsh` whenever it exists — including when 1Password
   is *not* active, so a signed-out shell still gets the last good secrets
6. If 1Password is not active, prints one warning naming the cause and what
   was loaded instead, e.g. `not signed in to 1Password: personal — using
   cached secrets (older than the template); run op_identity, then
   refresh_shell_secrets`. Machines with the `no_op` sentinel stay quiet.
7. Sets up `SSH_AUTH_SOCK` to point at the 1Password SSH agent (macOS only,
   skipped when in an SSH connection)

**`login`** — same order, but steps 2–3 become a per-account check:
`op whoami` for each `login-accounts` entry, with one `op signin` attempt
for any that are signed out. With desktop-app integration that attempt is
what shows Touch ID: authorization is per terminal tab and per account, so
every new tab prompts. `_ZDOT_OP_ACTIVE=1` only when every account is
signed in; `op_identity` (or `op_auth`) signs in whatever is still signed
out.

**`lazy-login`** (recommended over `login` — see *Login modes* below):
steps 2–3 are skipped. Startup makes no `op` calls; it sets
`_ZDOT_OP_ACTIVE=1` ("set up") and `_ZDOT_OP_SESSION=pending`. Step 4 only
needs `op` when a template is newer than its cache, and that first `op` call
runs the per-account check. A new tab with up-to-date caches never prompts.

Interactive prompts (first-time setup, service account creation) only fire in
interactive shells. Noninteractive shells silently skip setup if no cache exists.

---

## Configuration

All configuration is done via `zstyle` from within a `secrets-configure` group
hook (see below). The following zstyles are read by `op_get_vault_config` inside
`op_identity`:

| zstyle key | Default | Purpose |
|---|---|---|
| `':zdot:secrets:op' mode` | `service-account` | Auth mode. `service-account` (default): the identity is a service-account token, cached in `$USER.op-secrets.zsh` and good for the whole session — see *First-time interactive setup*. `login`: the identity is a set of signed-in sessions, checked at startup; the service-account machinery (op-secrets template, token cache, `OP_SERVICE_ACCOUNT_TOKEN`) is ignored entirely. `lazy-login`: the same, but checked at the first `op` call that's actually needed, so tabs with up-to-date caches never prompt — recommended over `login`. The login modes are for machines without service accounts (e.g. work) |
| `':zdot:secrets:op' login-accounts` | *(unset)* | Login modes: the accounts to sign in, as shorthands (e.g. `personal allenai`). Each is checked individually (`op whoami --account <a>`); 1Password counts as usable only when every one is signed in, and `op_identity` / `op_auth` sign in the ones that aren't. Does NOT configure injection — that comes from the account-*tagged* refs in the template (see `op_multi_inject`) |
| `':zdot:secrets:op' service-acct-vault` | `ServiceAcct` | Vault where per-host service account credentials are stored (service-account mode only) |
| `':zdot:secrets:op' api-vault` | `API` | Vault containing API keys / tokens |
| `':zdot:secrets:op' ssh-vault` | `SSHKeys` | Vault containing SSH keys |
| `':zdot:secrets:op' service-acct-grants` | `(API:read_items,write_items SSHKeys:read_items,write_items)` | Array of `vault:permissions` strings granted to newly created service accounts |
| `':zdot:secrets' ssh-platforms` | `(mac)` | Platform names or `$OSTYPE` globs; SSH agent setup only runs when at least one matches. Accepts `mac`, `linux`, `debian`, or raw globs like `darwin*` |
| `':zdot:secrets' ssh-func` | *(unset)* | Name of a function to call as an additional gate; setup only proceeds if it returns 0 |
| `':zdot:secrets' profile` | *(unset)* | Profile used to derive a suffix eg secrets-${PROFILE}.zsh for sourcing secrets from |
| `':zdot:secrets:op' default-account` | *(unset)* | Account shorthand that RAW `op://` refs in a tagged template resolve against (the default inject pass runs first). Unset and raw refs present → `op_multi_inject` rejects the template |

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
zstyle ':zdot:modules' search-path "${XDG_CONFIG_HOME}/zsh/modules"
zdot_load_module secrets              # built-in
zdot_load_module my-secrets          # your configure hook (found in search-path)
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
| `op_identity` | Establish this machine's 1Password identity. Service-account mode: create or choose the service account (interactive), write its template, inject the token cache. Login modes: check each account, sign in the rest, report each. Sets `_ZDOT_OP_ACTIVE`. `op_refresh` is the old name and still works. |
| `refresh_shell_secrets` | Re-inject the `secrets.zsh` template into its cache and source the result, via `op_inject_template`. Needs a signed-in 1Password: in an interactive shell a signed-out account is re-asked for (warning, then `op_auth`); scripts and startup only warn. Service-account mode only warns when the token isn't loaded. The mcp module's `refresh_mcpservers_secret` behaves the same way. |
| `op_auth` | Sign in (interactive only). Login modes: signs people in — every `login-accounts` entry, or `op_auth <name>` for one; names resolve via `':zdot:secrets:op:<name>' account-url`. Service-account mode: uses the token if it works (loading it from the cache if needed); otherwise errors and points at `op_identity` — it never creates a service account. `--reset` forgets the accounts and drops cached credentials first. |
| `op_get_vault_config` | Return vault names in `$reply` as name/value pairs (`svc`/`api`/`ssh`) — read into `typeset -A _v`; consumer pattern in the function header. |
| `op_get_vault_grants` | Return the service-account grant ARRAY in `$reply` (zstyle `service-acct-grants`, or the default derived from the api/ssh vault names passed as args). |
| `op_get_config_dir` | Print the `op` config directory (sudo-aware). |
| `op_get_config_args` | Print `--config <dir>` args for `op` invocations (one token per line). |
| `op_inject_template` | Inject one template to one output file: account-tagged (`op-<acct>://…`) templates go through `op_multi_inject`, plain ones through `op inject`. Shared by the shell-secrets and mcp refreshers. |
| `op_multi_inject` | `op inject` work-alike for account-tagged templates: one inject pass per account — a single pipeline for one or two accounts, a loop beyond that; all-or-nothing; never sources its output. See *Multiple accounts*. |

### Global state

| Variable | Values | Meaning |
|---|---|---|
| `_ZDOT_OP_ACTIVE` | `0` / `1` | `1` when 1Password is set up for use: the service-account token is loaded, or (`login`) every account is signed in, or (`lazy-login`) configured but not yet checked. Other modules gate on this before using `op`. |
| `_ZDOT_OP_SESSION` | `""` / `pending` / `ok` / `failed` | `lazy-login` only (empty otherwise). `pending`: sessions not checked yet; the first `op` call checks them. `ok`/`failed`: the result. After `failed`, an `op` command you run in an interactive shell checks again and re-asks; in scripts and during startup it's refused with a hint, so there's no prompt per command. `op_identity` also re-checks. |

---

## First-time interactive setup

### Service-account mode (default)

On first login in an interactive shell, if no `op` config or service account
exists, `op_identity` will:

1. Sign you in — prompts to sign in to 1Password if needed. Choosing `c`
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
no interactive prompts fire. The token lasts the whole session: `op_auth`
just confirms it works, and if it's missing or broken `op_auth` says to run
`op_identity` rather than setting it up itself.

### Login modes

Set the mode in a `secrets-configure` hook. We recommend `lazy-login`:

```zsh
zstyle ':zdot:secrets:op' mode lazy-login
```

Why lazy: with desktop-app integration, 1Password authorizes the CLI per
terminal tab and per account (10 minutes idle, 12 hours max, revoked when
the app locks). In `login` mode startup checks every account, so every new
tab asks for Touch ID once per account. In `lazy-login` a tab only asks when
it actually needs `op` — a template newer than its cache, or a command you
run — and otherwise uses the cached secrets. Service-account mode doesn't
need this: the token lasts the session and never prompts.

`op_auth` signs the accounts in; `op_identity` does the same and then
reports each account. Service accounts are never created, and
`$XDG_CONFIG_HOME/secrets/op-secrets.zsh` (if it exists from before) is
ignored. Shell secrets still refresh via `refresh_shell_secrets` — `op inject`
works identically under a signed-in session.

#### Multiple accounts

When the CLI can see more than one account (e.g. personal + allenai), *bare*
`op whoami`/`op inject` fail — they cannot disambiguate, and `op://` secret
references carry no account segment. Tag the references in your template
instead — the tag selects the account:

```zsh
# $XDG_CONFIG_HOME/secrets/secrets.zsh
export GITHUB_TOKEN="op-personal://Private/GitHub Token/credential"
export OPENAI_API_KEY="op-allenai://Work-API/OpenAI/api_key"
export WORK_CDN="op://Raw/Item/f"                    # raw ref — needs default
zstyle ':zdot:secrets:op' login-accounts personal allenai   # viability
zstyle ':zdot:secrets:op' default-account personal          # raw-ref account
```

Account names are passed straight to `op --account`, so a name that is a CLI
shorthand (`op account add --shorthand <name>`) needs nothing else. For one
that isn't, map it to its sign-in address with a per-account context, one
line per account:

```zsh
zstyle ':zdot:secrets:op:personal' account-url my.1password.com
zstyle ':zdot:secrets:op:allenai'  account-url allenai.1password.com
```

Use the per-account context: repeating `zstyle ':zdot:secrets:op'
account-url …` would replace the earlier value rather than add to it. Tags in
templates and all messages keep the short name; only the `op` calls use the
mapped address.

`refresh_shell_secrets` resolves the template through `op_inject_template`,
which hands tagged templates to `op_multi_inject`:

- Accounts derive from the tags (`op-<acct>://`) themselves — pass 1 seds
  `op-personal://` → `op://` and injects with `--account personal`; its
  output feeds pass 2 for the next tag, and so on. One or two passes run as a
  single pipeline; three or more run as a loop. No temp files; passes are
  order-independent, resolved values can never be re-resolved, and a
  failing pass names its account.
- `login-accounts` is the *viability* authority (startup checks, recovery);
  the tags are the *inject* authority. A tagged account that is signed out
  at inject time → error, nothing is written (last good cache stays).
- Raw `op://` refs resolve against `default-account`'s pass (which runs
  first). Raw refs with no default configured → rejected with an error.
- The merged cache (`${USER}.secrets.zsh`) is sourced once when done.
- `op_multi_inject` is general-purpose: it never sources its output, so you
  can point it at machine configs too (e.g. an mcp JSON mixing both
  accounts' keys).
- In `login` mode, startup checks each account and, if one is signed out,
  tries `op signin` for it before warning; if any stay signed out, the
  warning names them. In `lazy-login` the same check runs at the first `op`
  call that needs it.
- Recovery: `op_auth` (or `op_identity`) signs into each signed-out
  `login-accounts` entry; `op_identity` then reports per-account status.

With desktop-app integration, each new terminal tab has to authorize each
account (Touch ID). `op whoami` alone never prompts; `op signin`, `op inject`
and other commands do when the tab isn't authorized yet. That's the reason
to use `lazy-login`: tabs with up-to-date caches never reach `op` at all.

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
