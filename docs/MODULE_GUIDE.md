# Module Writer's Guide

This guide covers everything you need to write a zdot module, from a 3-line
quick start to complex plugin-loading lifecycles.

## Table of Contents

- [Quick Start](#quick-start)
- [Module Structure](#module-structure)
- [Choosing Your Approach](#choosing-your-approach)
- [zdot_simple_hook](#zdot_simple_hook)
- [zdot_define_module](#zdot_define_module)
- [Manual Hooks](#manual-hooks)
- [Common Patterns](#common-patterns)
- [Registering in .zshrc](#registering-in-zshrc)
- [API Reference](#api-reference)

---

## Quick Start

Create `lib/mymod/mymod.zsh`:

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
lib/mymod/
    mymod.zsh          # Required: main module file
    functions/          # Optional: autoloaded function files
        myfunc          # Each file = one function (lazy loaded)
        otherfunc
    config/             # Optional: static config files
```

**Naming conventions:**
- Directory and file share the same name: `lib/foo/foo.zsh`
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

## zdot_simple_hook

Convention-over-configuration sugar for the most common pattern: one function,
one hook, standard dependencies.

### Defaults

| Property | Default | Override |
|----------|---------|---------|
| Function | `_<name>_init` | `--fn <name>` |
| Requires | `xdg-configured` | `--requires <phases...>` or `--no-requires` |
| Provides | `<name>-configured` | `--provides <token>` |
| Contexts | `interactive noninteractive` | `--context <ctx...>` |

All unrecognized flags pass through to `zdot_register_hook`.

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
#     --requires xdg-configured --provides sudo-configured
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

**Optional dependency:**

```zsh
_uv_init() { ... }

zdot_simple_hook uv --requires secrets-loaded --optional
```

**Multiple requires (replaces the default):**

```zsh
_apt_init() { ... }

zdot_simple_hook apt --requires xdg-configured env-configured \
    --provides apt-ready \
    --provides-tool op --provides-tool eza
```

Note: `--requires` replaces the default `xdg-configured`. Include it explicitly
if you still need it alongside other requires.

---

## zdot_define_module

Multi-phase module definition for plugin-loading modules. Auto-derives hook
names and phase tokens from a basename.

### Phase Flags

Each takes a function name (the function must be defined before calling
`zdot_define_module`):

| Flag | Hook Name | Provides | Behavior |
|------|-----------|----------|----------|
| `--configure <fn>` | `<name>-configure` | `<name>-configured` | Eager, requires `xdg-configured` |
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
xdg-configured --> <name>-configure --> <name>-load --> <name>-post-init
                   (provides              (provides       (provides
                    <name>-configured)     <name>-loaded)  <name>-post-configured)
```

If only load exists (no configure), there's no auto-derived dependency on a
configure phase.

---

## Manual Hooks

For modules that don't fit either sugar, use `zdot_register_hook` directly.

### When to Go Manual

- Multiple independent hooks with different dependency chains
- Special flags like `--optional`, `--deferred-prompt`, `--requires-tool`
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
    --requires xdg-configured \
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
    --requires xdg-configured \
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

### Loading Modules

```zsh
zdot_load_module mymod
```

Load order in `.zshrc` doesn't determine execution order -- the dependency
DAG does. But grouping related modules together aids readability.

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

### Module Utilities

| Function | Purpose |
|----------|---------|
| `zdot_module_autoload_funcs [names]` | Autoload functions from `functions/` |
| `zdot_module_dir` | Get current module's directory (sets `REPLY`) |
| `zdot_module_path <name>` | Get a module's file path (sets `REPLY`) |
| `zdot_verify_tools <tools...>` | Verify tools are available |
| `zdot_has_tty` | Check if a TTY is available |
| `zdot_interactive` | Check if shell is interactive |
| `zdot_is_macos` / `zdot_is_linux` | Platform checks |

### Orchestration (in .zshrc)

| Function | Purpose |
|----------|---------|
| `zdot_allow_defer <fn> [phases]` | Acknowledge force-deferred hook |
| `zdot_defer_order <name1> <name2> [...]` | Order deferred hooks |
| `zdot_init` | Build and execute the hook plan |
