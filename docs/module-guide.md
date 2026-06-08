# Module Writer's Guide

This guide covers everything you need to write a zdot module, from a 3-line
quick start to complex plugin-loading lifecycles.

## Table of Contents

- [Quick Start](#quick-start)
- [Module Structure](#module-structure)
- [Choosing Your Approach](#choosing-your-approach)
- [Foundation phases: xdg-configured and bootstrap-ready](#foundation-phases-xdg-configured-and-bootstrap-ready)
- [zdot_simple_hook](#zdot_simple_hook)
- [zdot_define_module](#zdot_define_module)
- [Manual Hooks](#manual-hooks)
- [User Extension Points](#user-extension-points)
- [Common Patterns](#common-patterns)
- [Registering in .zshrc](#registering-in-zshrc)
- [API Reference](#api-reference)

---

## Quick Start

Create `modules/mymod/mymod.zsh`:

```zsh
#!/usr/bin/env zsh
# mymod: Description of what this module does

_mymod_init() {
    # Your initialization code here
    export MY_SETTING="value"
}

zdot_simple_hook mymod
```

Register it in `.zshrc` (anywhere in the module loading section):

```zsh
zdot_load_module mymod
```

Done. The hook system handles ordering automatically.

---

## Module Structure

```
modules/mymod/
    mymod.zsh          # Required: main module file
    functions/          # Optional: autoloaded function files
        myfunc          # Each file = one function (lazy loaded)
        otherfunc
    config/             # Optional: static config files
```

**Naming conventions:**
- Directory and file share the same name: `modules/foo/foo.zsh`
- Init function: `_<name>_init` (e.g., `_mymod_init`)
- Phase tokens: `<name>-configured`, `<name>-loaded`, `<name>-ready`

### Autoloaded Functions

Place individual function files in `functions/`. Call `zdot_module_autoload_funcs`
to register them:

```zsh
zdot_module_autoload_funcs          # Autoload all files in functions/
zdot_module_autoload_funcs foo bar  # Autoload only named functions
```

Functions are lazy-loaded via `autoload -Uz` -- they're only read from disk
when first called. Files starting with `_` are skipped (compinit discovers
those via fpath).

**Timing matters**: If your init function calls autoloaded functions, place
`zdot_module_autoload_funcs` before the init function definition. If the
autoloaded functions are user-facing only, place it at the end of the file.

---

## Choosing Your Approach

```
Does your module load third-party plugins?
  YES --> Does it have configure + load + post-init phases?
    YES --> zdot_define_module
    NO  --> zdot_define_module (even just --load-plugins is useful)
  NO --> Does it register more than one hook?
    YES --> Manual zdot_register_hook
    NO  --> zdot_simple_hook
```

| Approach | Best for | Examples |
|----------|----------|---------|
| `zdot_simple_hook` | Single-hook modules (most modules) | sudo, env, brew, ssh, aliases |
| `zdot_define_module` | Plugin-loading modules with lifecycles | tmux, nodejs, fzf, autocomplete |
| Manual `zdot_register_hook` | Multi-hook modules, special flags, hybrid | venv, secrets, completions |

---

## Foundation phases: xdg-configured and bootstrap-ready

Two phases sit at the base of every module's dependency chain:

| Phase | Provided by | Meaning |
|-------|-------------|---------|
| `xdg-configured` | `xdg` (first member of the `bootstrap` group) | XDG Base Directory env vars (`XDG_CONFIG_HOME`, etc.) are exported. |
| `bootstrap-ready` | `bootstrap` module | Initial per-machine setup is complete: **everything in the `bootstrap` group — `xdg` included — has run.** |

`bootstrap-ready` is the **default `--requires`** for both `zdot_simple_hook`
and the `zdot_define_module` configure phase. `xdg` is the first member of the
`bootstrap` group (it has no dependencies, so it sorts first), and `bootstrap-ready`
is the group's completion — so depending on `bootstrap-ready` transitively
guarantees XDG is set up. Most modules should just take the default and never
name `xdg-configured` directly.

**`bootstrap` group** — register early per-machine setup here and it is
guaranteed to run (after `xdg`, which is itself a member) before `bootstrap-ready`
is provided:

```zsh
zdot_register_hook _my_machine_setup interactive noninteractive \
    --group bootstrap
```

The shipped `xdg` and `local_env` (in `local_rc`, which sources `~/.zshenv_local`)
hooks are members of this group.

**When to require `xdg-configured` instead of `bootstrap-ready`:** only a hook
that itself runs *inside* `bootstrap` and needs the XDG dirs before the rest of
the group (e.g. `local_env`). It can't depend on `bootstrap-ready` — that's the
group's own completion, so it would be circular — so it requires `xdg-configured`
(provided by the `xdg` member) instead. Nothing **outside** the group treats xdg
specially: the coordinator just `--requires-group bootstrap`.

---

## zdot_simple_hook

Convention-over-configuration sugar for the most common pattern: one function,
one hook, standard dependencies.

### Defaults

| Property | Default | Override |
|----------|---------|---------|
| Function | `_<name>_init` | `--fn <name>` |
| Requires | `bootstrap-ready` | `--requires <phases...>` or `--no-requires` |
| Provides | `<name>-configured` | `--provides <token>` |
| Contexts | `interactive noninteractive` | `--context <ctx...>` |

All unrecognized flags pass through to `zdot_register_hook`. To expose a
user-extension group, pass `--requires-group <name>-configure` directly —
see [User Extension Points](#user-extension-points).

### Examples

**Simplest -- pure defaults:**

```zsh
_sudo_init() {
    if [[ ${SUDO_USER} != "" ]]; then
        REAL_HOME="${HOME:h}/${USER}"
        ZSH_TMUX_AUTOSTART="false"
    fi
}

zdot_simple_hook sudo
# Expands to: zdot_register_hook _sudo_init interactive noninteractive \
#     --requires bootstrap-ready --provides sudo-configured
```

**Custom provides token:**

```zsh
_bun_init() { ... }

zdot_simple_hook bun --provides bun-ready
```

**No auto-requires, interactive only:**

```zsh
_aliases_init() { ... }

zdot_simple_hook aliases --no-requires --context interactive
```

**Tool provider (passthrough flags):**

```zsh
_brew_init() {
    zdot_is_macos || return 0
    eval "$(/opt/homebrew/bin/brew shellenv)"
    zdot_verify_tools op eza oh-my-posh gh tailscale
}

zdot_simple_hook brew --provides brew-ready \
    --provides-tool op --provides-tool eza --provides-tool oh-my-posh \
    --provides-tool gh --provides-tool tmux --provides-tool tailscale
```

**Optional dependency** (skip the hook if the dependency is missing):

```zsh
_uv_init() { ... }

zdot_simple_hook uv --requires secrets-loaded --optional
```

**Soft ordering** (run *after* something if it exists, else proceed unordered):

```zsh
# Run after whoever provides the `fzf` tool, but only if some module does.
# On a machine without fzf the ordering is dropped and this hook still runs.
zdot_simple_hook history --after-tool fzf
```

`--after <target>` / `--after-tool <tool>` is the **soft** counterpart to
`--requires` / `--requires-tool`. Compare the three absence behaviours:

| | target/dep missing |
|---|---|
| `--requires-tool fzf` | hard error |
| `--requires-tool fzf` + `--optional` | the whole hook is skipped |
| `--after-tool fzf` | silent no-op — the hook still runs, just unordered |

Each `--after` target resolves as a phase first (so `--after-tool fzf` →
`tool:fzf` → whoever `--provides-tool fzf`), then as a hook name (so
`--after some-hook` orders after that hook directly). It is the declarative,
per-hook form of [`zdot_defer_order`](api-reference.md#zdot_defer_order); use
`--after` when the hook itself knows what it wants to follow, and
`zdot_defer_order` to order unrelated hooks from the outside.

**Multiple requires (replaces the default):**

```zsh
_apt_init() { ... }

zdot_simple_hook apt --requires bootstrap-ready env-configured \
    --provides apt-ready \
    --provides-tool op --provides-tool eza
```

Note: `--requires` replaces the default `bootstrap-ready`. Include it explicitly
if you still need it alongside other requires. (`bootstrap-ready` transitively
guarantees `xdg-configured`, so you rarely need to list xdg separately.)

---

## zdot_define_module

Multi-phase module definition for plugin-loading modules. Auto-derives hook
names and phase tokens from a basename.

### Phase Flags

Each takes a function name (the function must be defined before calling
`zdot_define_module`):

| Flag | Hook Name | Provides | Behavior |
|------|-----------|----------|----------|
| `--configure <fn>` | `<name>-configure` | `<name>-configured` | Eager, requires `bootstrap-ready` |
| `--load <fn>` | `<name>-load` | `<name>-loaded` | Eager, requires `<name>-configured` if configure exists |
| `--load-plugins <specs>` | `<name>-load` | `<name>-loaded` | Like `--load` but auto-generates the loader function |
| `--post-init <fn>` | `<name>-post-init` | `<name>-post-configured` | Deferred, requires `<name>-loaded` (or override) |
| `--interactive-init <fn>` | `<name>-interactive-init` | `<name>-interactive-ready` | Deferred, interactive only |
| `--noninteractive-init <fn>` | `<name>-noninteractive-init` | `<name>-noninteractive-ready` | Eager, noninteractive only |

`--load` and `--load-plugins` are mutually exclusive.

### Modifier Flags

| Flag | Effect |
|------|--------|
| `--context <ctx...>` | Default contexts for all phases (default: both) |
| `--configure-context <ctx...>` | Override context for configure phase only |
| `--load-context <ctx...>` | Override context for load phase only |
| `--post-init-context <ctx...>` | Override post-init context (default: interactive) |
| `--post-init-requires <phases...>` | Override post-init requires (default: `<name>-loaded`) |
| `--provides-tool <tool>` | Tool provided by the load phase |
| `--requires-tool <tool>` | Tool required by the load phase |
| `--requires <phases...>` | Extra requires for the load phase |
| `--group <name>` | Group for the load phase |
| `--auto-bundle` | Auto-detect bundle groups from plugin specs |
| `--auto-configure-group` | Expose the `<basename>-configure` extension group. The `--configure` fn (or `--load` fn, if no configure) becomes the group consumer via `--requires-group <basename>-configure` — it runs after all user hooks. See [User Extension Points](#user-extension-points). |
| `--variant <name>` | Only register phases when this variant is active (repeatable) |
| `--variant-exclude <name>` | Skip all phases when this variant is active |

### Examples

**Simplest -- auto-generated loader with bundle detection:**

```zsh
#!/usr/bin/env zsh
# tmux: OMZ tmux plugin integration

zdot_define_module tmux \
    --load-plugins omz:plugins/tmux \
    --auto-bundle
```

`--auto-bundle` detects the `omz:` prefix and injects `--group omz-plugins`
and `--requires plugins-cloned omz-bundle-initialized`.

**Full lifecycle with explicit functions:**

```zsh
_node_configure() {
    zstyle ':omz:plugins:nvm' lazy yes
    export NVM_DIR="${XDG_DATA_HOME}/nvm"
}

_nvm_interactive_init() {
    (( ${+functions[nvm]} )) || return 0
    zdot_defer_until -q 1 nvm use node --silent
}

_nvm_noninteractive_init() {
    (( ${+functions[nvm]} )) || return 0
    nvm use node --silent >/dev/null
}

zdot_define_module node \
    --configure _node_configure \
    --load-plugins omz:plugins/npm omz:plugins/nvm \
    --auto-bundle \
    --provides-tool nvm \
    --interactive-init _nvm_interactive_init \
    --noninteractive-init _nvm_noninteractive_init
```

**Explicit load function with group dependencies:**

```zsh
_fzf_plugins_load_omz() {
    zdot_has_tty && zdot_load_plugin omz:plugins/fzf
    zdot_verify_tools fzf
}

zdot_define_module fzf \
    --configure _fzf_init \
    --load _fzf_plugins_load_omz \
    --post-init _fzf_post_plugin \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized \
    --provides-tool fzf
```

Use `--load` (explicit function) instead of `--load-plugins` when you need
conditional loading logic, tool verification, or other custom behavior.

**Custom post-init dependencies:**

```zsh
zdot_define_module autocomplete \
    --configure _autocomplete_plugins_configure \
    --load _autocomplete_plugins_load \
    --post-init _autocomplete_plugins_post_init \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized \
    --post-init-requires autosuggest-abbr-ready \
    --post-init-context interactive noninteractive
```

`--post-init-requires` overrides the default dependency on `<name>-loaded`,
letting you depend on external phases from other modules.

**Multiple modules in one file:**

```zsh
# Two independent load phases for different plugins
zdot_define_module fzf \
    --configure _fzf_init \
    --load _fzf_plugins_load_omz \
    --post-init _fzf_post_plugin \
    ...

zdot_define_module fzf-tab \
    --load _plugins_load_fzf_tab \
    --requires autosuggest-abbr-ready fzf-configured \
    --context interactive
```

Each `zdot_define_module` call creates an independent lifecycle. Use this when
a file manages plugins with different dependency chains.

### Auto-wiring Rules

When both configure and load phases exist, load automatically requires
`<name>-configured`. This creates the pipeline:

```
bootstrap-ready --> <name>-configure --> <name>-load --> <name>-post-init
                    (provides             (provides       (provides
                     <name>-configured)    <name>-loaded)  <name>-post-configured)
```

(`bootstrap-ready` is the standard baseline — it sits above `xdg-configured`
and the per-machine `bootstrap` group; see [Foundation phases](#foundation-phases-xdg-configured-and-bootstrap-ready).)

If only load exists (no configure), there's no auto-derived dependency on a
configure phase.

---

## Manual Hooks

For modules that don't fit either sugar, use `zdot_register_hook` directly.

### When to Go Manual

- Multiple independent hooks with different dependency chains
- Special flags like `--optional`, `--deferred-prompt`, `--requires-tool`
- Variant-specific hooks that don't fit a module-level `--variant` flag
- Cross-cutting concerns (hooks in shared groups like `omz-configure`)
- Hooks that provide phases consumed by other modules

### Two-Hook Pipeline Example

```zsh
_venv_init() {
    export DEFAULT_PYTHON_VERSION=$(which python3.14)
}

_activate_global_venv() {
    [ -f ~/.venv/bin/activate ] && source ~/.venv/bin/activate
}

zdot_register_hook _venv_init interactive noninteractive \
    --requires bootstrap-ready \
    --provides venv-configured

zdot_register_hook _activate_global_venv interactive noninteractive \
    --requires venv-configured \
    --optional secrets-loaded \
    --provides venv-ready

zdot_module_autoload_funcs
```

### Tool-Gated Hook Example

```zsh
zdot_register_hook _op_init interactive noninteractive \
    --requires bootstrap-ready \
    --requires-tool op \
    --provides secrets-loaded
```

`--requires-tool op` means this hook only runs if another hook has
`--provides-tool op` (e.g., brew or apt).

### Group Hooks

```zsh
zdot_register_hook _omz_configure_completion interactive noninteractive \
    --name omz-configure-completion \
    --group omz-configure
```

Group hooks participate in barrier synchronization. All members of a group
must complete before anything that `--requires-group <name>` can run.

### Reserved groups: `pre-defer` and `finally`

Two group names are reserved by the scheduler. They use the **same begin/member/end
barrier synthesis as every other group** — so intra-group `--requires` are
honoured by the topological sort and members appear at their true position in
introspection. What's special is only how their begin barrier is ordered after
everything else:

| Group | Runs | Use for |
|-------|------|---------|
| `pre-defer` | The final **eager** step — after every other eager hook, just before the deferred phase begins (and, interactively, the first prompt). | Last-chance setup that must be in place before deferred work / on the very first prompt. |
| `finally` | Dead last — after every eager *and* deferred hook. In noninteractive shells the deferred drain is synchronous, so it still runs. | Teardown/cleanup that must outlast all other work (e.g. `xdg`'s `_xdg_cleanup` unsetting helper functions). |

```zsh
# Runs at the end of the eager pass, before deferred work:
zdot_register_hook _my_pre_defer interactive --group pre-defer

# Runs dead last, after deferred work:
zdot_register_hook _my_teardown interactive noninteractive --group finally
```

How each begin barrier is pushed last — and why the two differ:

- **`pre-defer`** must stay **eager**. Its begin barrier is ordered after every
  other eager hook with **synthetic Kahn-graph edges only** (via each
  predecessor's `_defer_order_<hid>` bridge phase), never real `--requires`.
  This is deliberate: the eager/deferred split isn't known until force-deferral
  runs *after* the sort, so a real dependency on a hook that later promotes to
  deferred would drag `pre-defer` into the deferred set too. Synthetic edges are
  invisible to force-deferral, so they can't promote it. (For introspection, the
  real, now-known-eager dependencies are recorded separately *after*
  force-deferral — they document the order in `zdot hook graph`; they don't
  enforce it.)
- **`finally`** must run after *everything*, deferred work included, so its begin
  barrier carries a **real `--requires` on every other in-plan hook** (each prior
  hook H is made to provide `_group_member_finally_<H>`, and the begin barrier
  requires it — the same member-phase mechanism a normal group's *end* barrier
  uses, applied to the *begin* barrier here). `finally` is therefore deferred
  **only if deferred hooks exist**: requiring a deferred hook's phase force-defers
  the begin barrier, cascading the whole subgraph into the deferred set, and the
  drain releases it last. If nothing is deferred, `finally` simply stays eager and
  runs last in the eager pass (like `pre-defer`, one step later). When the cascade
  does happen it is the whole point, not an accident, so the entire `finally`
  subgraph is pre-accepted (`zdot_allow_defer`-style) and the force-defer pass
  stays silent for it.

Members respect their own `--requires` and each other's; they only fire in
contexts where they survived into the execution plan. Both groups are standard
barriers whose begin gate is ordered last — `pre-defer` last among eager,
`finally` last of all.

---

## User Extension Points

User-injected configuration lands at one of two layers, and the mechanism is
different for each:

| Layer | When | Mechanism | Use when |
|---|---|---|---|
| **Parse-time** | While the module's `.zsh` file is being sourced | `zdot_before_module` callback registry | The module reads zstyle / shell state at parse time (e.g. `zdot_provides_tool_args`, conditional `zdot_use_plugin`) |
| **DAG-time** | While the resolved hook DAG is executing | `<name>-configure` group with `--requires-group` on the module's init fn | The module reads state inside an init/configure fn that runs during `zdot_init` |

Both layers share the same idiom inside the module: read state with a
backstop fallback (`zstyle -s ... || default`) so user-set values win, but
sensible defaults apply when nothing is set.

When the module reads the value itself, the inline fallback is enough. But when
something *else* reads the zstyle — e.g. an upstream plugin the module sources,
which looks up its own `:plugin:*` styles — the module must *seed* the default
into the style ahead of time. Use
[`zdot_zstyle_default`](api-reference.md#zdot_zstyle_default) for that: it sets a
value only when the style is unset, so any user value (from `.zshrc`, a
`zdot_before_module` callback, or a `*-configure` hook) still wins.

```zsh
# Seed upstream-plugin defaults the user can override; the plugin reads these.
zdot_zstyle_default ':zsh-ai:*'       endpoint 'http://localhost:11434/v1'
zdot_zstyle_default ':zsh-ai:scratch' enabled  yes
```

The rest of this section walks through DAG-time first (the common case),
then parse-time.

### DAG-time: zdot_simple_hook

Pass `--requires-group <name>-configure` directly; it falls through to
`zdot_register_hook`. The init fn is the consumer. User hooks attach with
`--group <name>-configure` and run before it.

```zsh
_brew_init() {
    eval "$(/opt/homebrew/bin/brew shellenv)"
    local -a _tools
    zstyle -a ':zdot:brew' verify-tools _tools \
        || _tools=(op eza oh-my-posh gh)        # backstop default
    zdot_verify_tools "${_tools[@]}"
}

zdot_simple_hook brew --provides brew-ready --requires-group brew-configure
```

```zsh
# User override (in .zshrc or another module)
_my_brew_overrides() {
    zstyle ':zdot:brew' verify-tools op fd ripgrep
}
zdot_register_hook _my_brew_overrides interactive noninteractive \
    --group brew-configure
```

Order: `user --group hooks` → `_brew_init`.

### DAG-time: zdot_define_module

`--auto-configure-group` does the wiring for you: the `--configure` fn (or
the `--load` fn, if no configure is set) becomes the group consumer. User
hooks attach with `--group <basename>-configure`.

```zsh
_node_configure() {
    zstyle -t ':omz:plugins:nvm' lazy \
        || zstyle ':omz:plugins:nvm' lazy yes   # backstop default
}

zdot_define_module node \
    --configure _node_configure \
    --load-plugins omz:plugins/nvm \
    --auto-bundle \
    --auto-configure-group
```

```zsh
# User override (in .zshrc or another module)
_my_node_overrides() {
    zstyle ':omz:plugins:nvm' lazy no
}
zdot_register_hook _my_node_overrides interactive noninteractive \
    --group node-configure
```

Resulting DAG:

```
bootstrap-ready
      ↓
  [ _my_node_overrides  ||  …other user hooks ]   ← group members
      ↓
  group end-barrier
      ↓
  _node_configure   ← consumer; reads zstyle, applies backstop defaults
      ↓ provides node-configured
  node-load
```

When there is no `--configure` fn, the `--load` fn takes the consumer
role — there is just one phase that does both "read user state" and
"do the work."

### Parse-time: zdot_before_module

Some modules read state *at parse time* — while the module file is being
sourced, before any DAG hook runs. Examples:

- `brew` / `apt` use `zdot_provides_tool_args ':zdot:brew' verify-tools …`
  at parse time to seed `--provides-tool` arguments on the registered hook.
- `history` gates a plugin declaration on `zstyle -T ':zdot:history' per-dir`
  at parse time.
- Any module that conditionally calls `zdot_use_plugin <spec>` based on
  shell state.

Setting these zstyles from a DAG-time configure-group hook is too late —
the DAG isn't built yet. The simplest fix is to set the zstyle in `.zshrc`
before `zdot_load_module`:

```zsh
zstyle ':zdot:brew' verify-tools op fd ripgrep
zdot_load_module brew
```

That works and needs no new API. Reach for `zdot_before_module` when one of
the following applies:

- You want to group several settings for one module into a single callback
- The setup has conditional logic (platform detection, env checks)
- You want a per-module config file that self-registers, so source order
  in `.zshrc` doesn't matter

The function has two forms:

```zsh
# Light: schedule a single command to run when the module is loaded
zdot_before_module brew --cmd zstyle ':zdot:brew' verify-tools op fd ripgrep

# Heavy: register a named function (define it elsewhere)
_my_brew_setup() {
    zstyle ':zdot:brew' verify-tools op fd ripgrep
    is-platform mac && zstyle ':zdot:brew' something-else yes
}
zdot_before_module brew --fn _my_brew_setup
```

Callbacks fire synchronously, in registration order, immediately before the
module is sourced. Multiple `zdot_before_module` calls for the same module
all run.

```zsh
# These accumulate; all three run in order before brew is sourced.
zdot_before_module brew --cmd zstyle ':zdot:brew' verify-tools op fd ripgrep
zdot_before_module brew --cmd export HOMEBREW_NO_AUTO_UPDATE=1
zdot_before_module brew --fn _my_extra_brew_setup
zdot_load_module brew
```

Per-module config files become self-registering:

```zsh
# ~/.config/zsh/modules-config/brew.zsh
_my_brew_setup() {
    zstyle ':zdot:brew' verify-tools op fd ripgrep
    [[ -x /opt/homebrew/bin/brew ]] && zstyle ':zdot:brew' something yes
}
zdot_before_module brew --fn _my_brew_setup
```

```zsh
# .zshrc
source ~/.config/zsh/modules-config/brew.zsh   # registers itself
zdot_load_module brew                          # callback fires here
```

Behaviour and edge cases:

- `--fn` and `--cmd` are mutually exclusive; exactly one must be given.
- `--fn` registrations are deduplicated by function name. `--cmd`
  registrations are not (each call generates a distinct anonymous fn).
- `--fn` accepts a function name that isn't defined yet — the framework
  warns at drain time if it's still missing, then continues to the next
  callback. Useful when registration precedes definition.
- Registering after the module has already been loaded warns and the
  callback does not run. Order matters: register before `zdot_load_module`.
- A callback for a module that's never loaded silently never fires.

#### Cross-module configuration

`zdot_before_module` isn't restricted to `.zshrc` — any module can register
parse-time callbacks for *other* modules. This is the parse-time analogue
of one module setting zstyles a DAG hook will read.

```zsh
# Inside a user module ~/.config/zdot-modules/macos-defaults/macos-defaults.zsh
zdot_before_module brew --cmd zstyle ':zdot:brew' verify-tools op eza fzf
zdot_before_module brew --cmd zstyle ':zdot:brew' some-other-key yes
zdot_before_module fzf  --fn  _macos_fzf_prepare

_macos_fzf_prepare() {
    zstyle ':zdot:fzf' theme "$HOME/.config/fzf/tokyonight.sh"
}
```

```zsh
# In .zshrc
zdot_load_module xdg
zdot_load_module macos-defaults    # registers callbacks for brew + fzf
zdot_load_module brew              # macos-defaults' brew callbacks fire here
zdot_load_module fzf               # _macos_fzf_prepare fires here
```

Registering for a module that never loads is a silent no-op, so a defaults
module can offer setup for several optional targets and only the ones the
user actually loads take effect.

##### Ordering constraint

`zdot_load_module` is a single-shot operation — it both declares and sources
the module immediately, unlike `zdot_use_plugin` / `zdot_load_plugin` which
split declaration from loading. That means **a module M can only configure
module N via `zdot_before_module` if M is sourced before
`zdot_load_module N`**.

```zsh
zdot_load_module xdg               # OK, runs before brew
zdot_load_module macos-defaults    # OK, configures brew and fzf below

zdot_load_module brew              # macos-defaults' brew callbacks ran
zdot_load_module fzf               # macos-defaults' fzf callbacks ran

zdot_load_module late-tweaker      # ❌ TOO LATE for brew and fzf;
                                   # late registrations warn and skip
```

The DAG configure-group mechanism has no such constraint — those hooks
register at parse time but execute at DAG time, so ordering between
modules doesn't matter. `zdot_before_module` fires *immediately* on
`zdot_load_module`, so source order does.

In practice, "cross-module configurator" modules (defaults, themes,
platform packs) want to load near the top of `.zshrc`, after foundation
modules like `xdg` but before any target they aim to influence.

### The backstop pattern

The point of having the module's fn run *after* user hooks is to make
override-via-zstyle natural. Users set state; the module reads it with a
fallback (`zstyle -s ... || default`); load consumes the resolved state.
Nothing has to know about ordering beyond the group.

This means modules opting into `--auto-configure-group` should generally
phrase their defaults as fallbacks rather than direct assignments. A
direct `export NVM_DIR="…"` in the configure fn can't be overridden by
a user group hook (the user's hook runs first, then the configure fn
overwrites). Convert it to `: ${NVM_DIR:="…"}` or
`zstyle -s ':zdot:node' nvm-dir NVM_DIR || NVM_DIR="…"` to make it
override-friendly.

If a module's configure logic isn't expressible as backstop defaults,
users can still override it by registering a hook that runs *after* the
configure fn with `--requires <basename>-configured`:

```zsh
zdot_register_hook _my_late_node_tweak interactive noninteractive \
    --requires node-configured
```

This isn't a group hook — it's just a regular hook that depends on the
module's configure phase. Use sparingly; the backstop idiom inside the
module is preferred.

### Naming

The string `<basename>-configure` appears in two namespaces:
- as a **hook name** (the configure-phase hook in `zdot_define_module`)
- as a **group name** (the extension group when `--auto-configure-group` is set)

These live in separate lookup tables and never collide. Users always address
the group with `--group <basename>-configure`.

### When to expose one

Add `--auto-configure-group` to modules whose behaviour is reasonably tunable
via `zstyle` (or other pre-init state). Skip it for foundation modules like
`xdg` (nothing meaningful to configure before init), inherently user-specific
modules like `local_rc`, and `zdot_define_module` calls that have neither
`--configure` nor `--load` (the flag is ignored with a warning).

---

## Common Patterns

### Completion Registration

Register completions alongside your hook. These are processed during
the completions finalization phase:

```zsh
_rust_init() { ... }

zdot_simple_hook rust --provides rust-ready

zdot_register_completion_file "rustup" \
    "rustup completions zsh > $(zdot_get_completions_dir)/_rustup"
zdot_register_completion_file "cargo" \
    "rustup completions zsh cargo > $(zdot_get_completions_dir)/_cargo"
```

### Platform-Conditional Modules

Handle platform checks inside the init function, not at module scope:

```zsh
_brew_init() {
    zdot_is_macos || return 0
    # macOS-only setup...
}
```

Platform selection happens in `.zshrc`:

```zsh
if zdot_is_macos; then
    zdot_load_module brew
else
    zdot_load_module apt
fi
```

### Deferred Plugins

For plugins that must load after eager hooks complete, use `defer` with
`zdot_use_plugin`:

```zsh
zdot_use_plugin zsh-users/zsh-autosuggestions defer \
    --name autosuggest-load \
    --provides autosuggest-ready \
    --requires autocomplete-loaded
```

Deferred plugins are installed eagerly (cloned) but loaded after the
execution plan completes. Use `--requires` to sequence them.

### OMZ Plugin Integration

For modules that load Oh-My-Zsh plugins:

```zsh
# Declare for clone manifest
zdot_use_plugin omz:plugins/fzf

# Use zdot_define_module with --auto-bundle for automatic OMZ wiring
zdot_define_module fzf \
    --load-plugins omz:plugins/fzf \
    --auto-bundle
```

`--auto-bundle` detects `omz:` prefixes and injects:
- `--group omz-plugins`
- `--requires plugins-cloned omz-bundle-initialized`

For explicit load functions, specify these manually:

```zsh
zdot_define_module fzf \
    --load _fzf_load \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized
```

---

## Registering in .zshrc

### Module Search Path

By default, `${XDG_CONFIG_HOME}/zdot-modules` (typically
`~/.config/zdot-modules`) is automatically included in the search path if it
exists. Create it and place your modules there:

```
~/.config/zdot-modules/
└── mymod/
    └── mymod.zsh
```

To add additional directories (which shadow built-in modules of the same name),
set the search path before any `zdot_load_module` calls:

```zsh
zstyle ':zdot:modules' search-path \
  "${XDG_CONFIG_HOME}/zsh/modules" \
  ~/work/zsh-modules
```

Search order: zstyle paths (in order), then `${XDG_CONFIG_HOME}/zdot-modules`,
then the built-in `modules/` directory (always last).

### Loading Modules

```zsh
zdot_load_module mymod
```

Load order in `.zshrc` doesn't determine execution order -- the dependency
DAG does. But grouping related modules together aids readability.

Always load the `xdg` and `bootstrap` foundation modules — they provide
`xdg-configured` and `bootstrap-ready`, the phases nearly every other module
depends on by default. Omitting `bootstrap` leaves `bootstrap-ready` unprovided,
which stalls every module that requires it.

### Acknowledging Deferred Hooks

If a hook is force-deferred (its dependencies come from deferred hooks),
acknowledge it to suppress warnings:

```zsh
zdot_allow_defer _fzf_post_plugin
zdot_allow_defer _completions_finalize
```

### Ordering Deferred Hooks

When deferred hooks need a specific relative order that isn't expressed
by `--requires`/`--provides`:

```zsh
zdot_defer_order _hook_a _hook_b _hook_c
# Ensures: A runs before B, B runs before C
```

### Execution

After all modules are loaded and orchestration is configured:

```zsh
zdot_init
```

This triggers: clone -> bundle init -> group resolution -> plan -> execute.

---

## API Reference

### Sugar Functions

| Function | Purpose |
|----------|---------|
| `zdot_simple_hook <name> [flags]` | Single-hook module sugar |
| `zdot_define_module <name> [flags]` | Multi-phase module sugar |

### Core Functions

| Function | Purpose |
|----------|---------|
| `zdot_register_hook <fn> <ctx...> [flags]` | Register a hook |
| `zdot_use_plugin <spec> [defer] [flags]` | Declare a plugin for cloning |
| `zdot_load_plugin <spec>` | Load a plugin (call inside hook functions) |
| `zdot_load_module <name>` | Load a module file |
| `zdot_register_bundle <handler> [flags]` | Register a plugin bundle handler |
| `zdot_register_completion_file <name> <cmd>` | Register a completion generator |
| `zdot_register_completion_live <name> <cmd>` | Register a live completion |

**`zdot_register_hook` variant flags:**

| Flag | Effect |
|------|--------|
| `--variant <name>` | Only run in the named variant (repeatable for OR logic) |
| `--variant-exclude <name>` | Skip in the named variant |

`--variant` and `--variant-exclude` are mutually exclusive per call.
Hooks with neither flag run in all variants (default/backward-compatible behaviour).

### Module Utilities

| Function | Purpose |
|----------|---------|
| `zdot_module_autoload_funcs [names]` | Autoload functions from `functions/` |
| `zdot_module_dir` | Get current module's directory (sets `REPLY`) |
| `zdot_module_path <name>` | Get a module's file path (sets `REPLY`) |
| `zdot_verify_tools <tools...>` | Verify tools are available |
| `zdot_has_tty` | Check if a TTY is available |
| `zdot_interactive` | Check if shell is interactive |
| `zdot_is_macos` / `zdot_is_platform <name>` | Platform checks |
| `zdot_variant` | Print the active variant string (may be empty) |
| `zdot_is_variant <name>` | Return 0 if active variant matches `<name>` |

### Orchestration (in .zshrc)

| Function | Purpose |
|----------|---------|
| `zdot_allow_defer <fn> [phases]` | Acknowledge force-deferred hook |
| `zdot_defer_order <name1> <name2> [...]` | Order deferred hooks |
| `zdot_init` | Build and execute the hook plan |
