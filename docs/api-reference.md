# zdot API Reference

Complete reference for all public zdot functions, grouped by usage category.

> **Convention:** Functions prefixed with `_zdot_` or `_` are internal and not
> documented here. Only the public API that module authors and users should call
> is covered.

---

## Table of Contents

- [Initialization](#initialization)
- [Hook Registration](#hook-registration)
- [Hook Orchestration](#hook-orchestration)
- [Module Loading](#module-loading)
- [Plugin Management](#plugin-management)
- [Deferred Execution](#deferred-execution)
- [Platform & Context](#platform--context)
- [Logging](#logging)
- [Cache](#cache)
- [Completions](#completions)
- [Utilities](#utilities)
- [CLI](#cli)

---

## Initialization

### `zdot_init`

Single entry point for the entire zdot startup sequence. Call this once at the
end of your `.zshrc`, after all `zdot_load_module` calls.

```zsh
zdot_init
```

**What it does (in order):**

1. Clones all declared plugin repositories
2. Runs bundle init functions (OMZ, Prezto)
3. Resolves group annotations into DAG barrier hooks
4. Builds or loads the cached execution plan (topological sort)
5. Executes all eager hooks in dependency order
6. Kicks off deferred hooks (post-prompt via `zsh-defer`)
7. Compiles all modules to `.zwc` bytecode

Guards against double-invocation. You should never need to call any other
orchestration function directly.

**Example `.zshrc`:**

```zsh
source "${XDG_CONFIG_HOME}/zdot/zdot.zsh"

zdot_load_module xdg
zdot_load_module history
zdot_load_module brew
zdot_load_module plugins

zdot_init
```

---

## Hook Registration

These functions register shell functions as hooks in the dependency-aware
execution system. Hooks are topologically sorted and executed in the correct
order by `zdot_init`.

### `zdot_register_hook`

Full-control hook registration with explicit dependency metadata.

```zsh
zdot_register_hook <function-name> <context...> [flags...]
```

| Parameter | Description |
|-----------|-------------|
| `<function-name>` | Shell function to execute when this hook fires |
| `<context...>` | One or more of: `interactive`, `noninteractive`, `login`, `nonlogin` |

| Flag | Argument | Description |
|------|----------|-------------|
| `--requires` | `<phase...>` | Phases that must complete before this hook runs |
| `--requires-tool` | `<tool>` | Sugar for `--requires tool:<tool>` |
| `--after` | `<target...>` | **Soft** ordering: run after each target *if present*, else no-op (never errors, never skips the hook). Each target resolves as a phase first, else as a hook name. The declarative, soft counterpart to `--requires`; the per-hook counterpart to `zdot_defer_order`. |
| `--after-tool` | `<tool>` | Sugar for `--after tool:<tool>` — soft-order after whoever `--provides-tool <tool>`, if any. |
| `--before` | `<target...>` | **Soft** ordering mirror of `--after`: run *before* each target *if present*, else no-op (never errors, never skips the hook). Each target resolves as a phase first, else as a hook name. Lets a hook insert itself ahead of another without editing it. |
| `--before-tool` | `<tool>` | Sugar for `--before tool:<tool>` — soft-order before whoever `--provides-tool <tool>`, if any. |
| `--provides` | `<phase>` | Phase token this hook provides on completion |
| `--provides-tool` | `<tool>` | Sugar for `--provides tool:<tool>` |
| `--optional` | | Hook is skipped (not errored) if a required phase has no provider |
| `--name` | `<name>` | Human-readable label (used by `zdot_defer_order` and introspection) |
| `--deferred` | | Mark for post-prompt deferred execution |
| `--deferred-prompt` | | Like `--deferred` but refreshes the prompt afterward |
| `--group` | `<name>` | Add to a named group (may repeat). Three names are predefined: `bootstrap` (runs first), `pre-defer` (runs as the last eager step, before the deferred phase), and `finally` (runs last of all, after the deferred drain). See the [Module Guide](module-guide.md#predefined-groups-bootstrap-pre-defer-and-finally). |
| `--provides-group` | `<name>` | Provide into a named group |
| `--requires-group` | `<name>` | Require all members of the named group to complete |
| `--variant` | `<name>` | Only run when variant matches (may repeat; empty = all) |
| `--variant-exclude` | `<name>` | Exclude when variant matches (takes priority over `--variant`) |

Sets `REPLY` to the generated `hook_id` on success.

**Example:**

```zsh
_my_tool_init() {
  export MY_TOOL_HOME="${XDG_DATA_HOME}/my-tool"
  path=("${MY_TOOL_HOME}/bin" $path)
}

zdot_register_hook _my_tool_init interactive noninteractive \
  --requires bootstrap-ready \
  --provides my-tool-ready \
  --provides-tool my-tool \
  --name "my-tool"
```

---

### `zdot_simple_hook`

Sugar for the common single-hook module pattern. Derives sensible defaults from
a base name.

```zsh
zdot_simple_hook <name> [flags...]
```

**Auto-derived defaults:**
- Function: `_<name>_init`
- Requires: `bootstrap-ready`
- Provides: `<name>-configured`
- Context: `interactive noninteractive`

| Flag | Argument | Description |
|------|----------|-------------|
| `--provides` | `<phase>` | Override provides (default: `<name>-configured`) |
| `--requires` | `<phase...>` | Override requires (default: `bootstrap-ready`) |
| `--no-requires` | | Clear all auto-derived requires |
| `--context` | `<ctx...>` | Override contexts |
| `--fn` | `<name>` | Override function name |
| *(others)* | | Passed through to `zdot_register_hook` |

To expose a user-extension group, pass `--requires-group <name>-configure`
directly (it falls through to `zdot_register_hook`). Users then attach with
`--group <name>-configure`.

**Example:**

```zsh
# Registers _rust_init with requires=bootstrap-ready, provides=rust-configured
_rust_init() {
  source "$HOME/.cargo/env" 2>/dev/null
}
zdot_simple_hook rust
```

```zsh
# Custom overrides
_my_setup() { ... }
zdot_simple_hook my-thing \
  --fn _my_setup \
  --requires brew-ready \
  --provides-tool mytool
```

---

### `zdot_define_module`

Declarative multi-phase module definition. Auto-derives hook names and phase
tokens and wires up lifecycle dependencies.

```zsh
zdot_define_module <basename> [flags...]
```

Registers up to five lifecycle hooks from a single call:

| Phase | Triggered By | Default Provides | Context |
|-------|-------------|-----------------|---------|
| configure | `--configure <fn>` | `<basename>-configured` | eager, all |
| load | `--load <fn>` or `--load-plugins <specs>` | `<basename>-loaded` | eager, all |
| post-init | `--post-init <fn>` | `<basename>-post-configured` | deferred, interactive |
| interactive-init | `--interactive-init <fn>` | `<basename>-interactive-ready` | deferred, interactive |
| noninteractive-init | `--noninteractive-init <fn>` | `<basename>-noninteractive-ready` | eager, noninteractive |

| Flag | Argument | Description |
|------|----------|-------------|
| `--configure` | `<fn>` | Configure hook function (auto-requires `bootstrap-ready`) |
| `--load` | `<fn>` | Custom loader hook function |
| `--load-plugins` | `<specs...>` | Auto-generate loader from plugin specs |
| `--post-init` | `<fn>` | Post-init hook function |
| `--interactive-init` | `<fn>` | Interactive init hook function |
| `--noninteractive-init` | `<fn>` | Non-interactive init hook function |
| `--context` | `<ctx...>` | Default contexts for all phases |
| `--provides-tool` | `<tool>` | Tool provided by the load phase (may repeat) |
| `--requires-tool` | `<tool>` | Tool required by the load phase (may repeat) |
| `--requires` | `<phase...>` | Extra requirements for the load phase |
| `--auto-bundle` | | Auto-detect bundle group/requires from plugin specs |
| `--group` | `<name>` | Explicit group for the load phase (may repeat) |
| `--auto-configure-group` | | Expose the `<basename>-configure` extension group. The `--configure` fn (or `--load` fn, if no configure) becomes the CONSUMER (`--requires-group`), running after all user group hooks. Requires at least one of `--configure` / `--load`. |
| `--configure-context` | `<ctx...>` | Override configure phase context |
| `--load-context` | `<ctx...>` | Override load phase context |
| `--post-init-requires` | `<phase...>` | Override post-init requires |
| `--post-init-context` | `<ctx...>` | Override post-init context |
| `--variant` | `<name>` | Only activate for this variant (may repeat) |
| `--variant-exclude` | `<name>` | Exclude for this variant (may repeat) |

**Example:**

```zsh
_fzf_configure() {
  export FZF_DEFAULT_OPTS="--height 40%"
}

_fzf_post_init() {
  bindkey '^T' fzf-file-widget
}

zdot_define_module fzf \
  --configure _fzf_configure \
  --load-plugins "junegunn/fzf" \
  --post-init _fzf_post_init \
  --provides-tool fzf
```

**With `--auto-configure-group` (extension point for downstream config):**

```zsh
zdot_define_module brew \
  --configure _brew_defaults \
  --load _brew_load \
  --auto-configure-group
```

Downstream code hooks into `brew-configure` to contribute pre-load
configuration:

```zsh
_my_brew_overrides() {
    zstyle ':zdot:brew' verify-tools op fd ripgrep
}
zdot_register_hook _my_brew_overrides interactive noninteractive \
    --group brew-configure
```

**Wiring.** `--auto-configure-group` exposes the `<basename>-configure`
extension group. The module's `--configure` fn (or `--load` fn, if no
configure is set) becomes the *consumer* of the group via
`--requires-group <basename>-configure`, so it runs after every
user-registered group hook. The DAG is:

```
bootstrap-ready
      ↓
  [ _my_brew_overrides  ||  …other user hooks ]   ← group members
      ↓
  group end-barrier
      ↓
  _brew_defaults    ← the module's --configure fn (consumer)
      ↓ provides brew-configured
  _brew_load
```

The module's configure fn (or load fn) is positioned to read state the
user hooks set — e.g. `zstyle -s ':zdot:brew' verify-tools _tools ||
_tools=(default fallback)`. The flag requires at least one of `--configure`
or `--load`; otherwise it is ignored with a warning.

---

## Hook Orchestration

These functions control hook execution order and behavior. They are typically
called in `.zshrc` before `zdot_init`.

### `zdot_allow_defer`

Pre-accept a hook as force-deferred, suppressing warnings.

```zsh
zdot_allow_defer <function-name> [<phase>...]
```

When a non-deferred hook depends on a phase provided only by a deferred hook,
zdot will automatically force-defer it. Call `zdot_allow_defer` to acknowledge
this is intentional.

**Example:**

```zsh
zdot_allow_defer _nodejs_init nodejs-configured
zdot_allow_defer _completions_init
zdot_init
```

---

### `zdot_defer_order`

Declare ordering constraints between named hooks without coupling them through
a shared phase.

```zsh
zdot_defer_order [--context <ctx>] <name-A> <name-B> [name-C ...]
```

Generates a full ordering chain: A before B, A before C, B before C, etc.

| Flag | Argument | Description |
|------|----------|-------------|
| `--context` | `<ctx>` | Only apply in the given context (e.g. `interactive`) |

**Example:**

```zsh
# Ensure fzf loads before shell-extras, which loads before autocompletion
zdot_defer_order fzf shell-extras autocompletion
```

**`zdot_defer_order` vs `--after`.** Both inject the same ordering-only
synthetic edge and share the same contradiction/cycle safety. Reach for
`zdot_defer_order` to order two *otherwise-unrelated* hooks by name from the
outside; a missing endpoint **warns** (it's treated as a probable typo). Reach
for [`--after`](#zdot_register_hook) when a hook itself declares "run me after
this capability, if present" — it resolves a phase/tool/hook target, a missing
target is a **silent no-op**, and the constraint lives on the dependent hook.
In short: `--after` is the declarative, soft, dependent-side counterpart;
`zdot_defer_order` is the imperative, warn-on-absence, third-party one.

---

### `zdot_build_execution_plan`

Builds the topologically-sorted execution plan from all registered hooks.

```zsh
zdot_build_execution_plan
```

> **Note:** You typically do not call this directly. `zdot_init` calls it
> for you. It is documented here for completeness and advanced use.

---

### `zdot_execute_all`

Runs every hook in the eager (non-deferred) execution plan.

```zsh
zdot_execute_all
```

> **Note:** Called internally by `zdot_init`. Documented for completeness.

---

## Module Loading

### `zdot_load_module`

Load a module by name.

```zsh
zdot_load_module <module-name>
```

Searches the configured module path in order:
1. User-supplied directories (via zstyle `:zdot:modules` `search-path`)
2. `${XDG_CONFIG_HOME}/zdot-modules` (default user dir, if it exists)
3. Built-in `modules/` directory

First match wins. Deduplicates automatically (loading the same module twice is
a no-op).

**Example:**

```zsh
zdot_load_module xdg
zdot_load_module brew
zdot_load_module history
```

---

### `zdot_before_module`

Register a callback to run synchronously before a module is sourced. Useful
for setting zstyles or other shell state that the module reads at parse time
(see [User Extension Points](module-guide.md#user-extension-points) for the
two-layer model).

```zsh
zdot_before_module <module-name> --fn  <function-name>
zdot_before_module <module-name> --cmd <command> [args...]
```

Exactly one of `--fn` / `--cmd` must be given.

| Flag | Description |
|------|-------------|
| `--fn <name>` | Register an existing function. Deduplicated by name. |
| `--cmd <cmd> [args…]` | Schedule a single command + args. The framework generates an anonymous function. Not deduplicated. |

Callbacks fire in registration order. `--fn` accepts a name that is not yet
defined; missing-at-drain warns and continues. Registering after the module
has been loaded warns and the callback does not run. Callbacks for modules
that never load silently never fire.

**Examples:**

```zsh
# Light: one-shot zstyle override
zdot_before_module brew --cmd zstyle ':zdot:brew' verify-tools op fd ripgrep

# Heavy: multi-statement setup or conditional logic
_my_brew_setup() {
    zstyle ':zdot:brew' verify-tools op fd ripgrep
    is-platform mac && zstyle ':zdot:brew' something-else yes
}
zdot_before_module brew --fn _my_brew_setup
```

For one-off zstyles, raw `zstyle … ; zdot_load_module <name>` in `.zshrc` is
lighter and adds no API surface. Reach for `zdot_before_module` when grouping
multiple settings, when setup is conditional, or when per-module config files
should self-register.

**Cross-module configuration**: any module M may register
`zdot_before_module N …` callbacks for another module N, provided M is
sourced before `zdot_load_module N`. Callbacks for modules that never load
are silent no-ops. See [User Extension Points →
Cross-module configuration](module-guide.md#cross-module-configuration) for
the full pattern.

---

### `zdot_module_path`

Find the filesystem path of a module.

```zsh
zdot_module_path <module-name>
```

Sets `REPLY` to the full path of `<name>/<name>.zsh`, or returns 1 if not found.

---

### `zdot_module_loaded`

Check whether a module has been loaded.

```zsh
zdot_module_loaded <module-name>
```

Returns 0 if the named module has been loaded via `zdot_load_module`, 1
otherwise. Useful inside a module's configure/init hooks to vary behaviour based
on which sibling modules the user has enabled.

By the time configure and init hooks run, all `zdot_load_module` calls in
`.zshrc` have completed, so the check reflects the user's full module selection
regardless of load order.

**Example:**

```zsh
# In modules/history/history.zsh — default the fzf ctrl-r binding on
# only when the user has also enabled the fzf module.
if zdot_module_loaded fzf; then
    zstyle ':contextual-history:*' fzf-bind-ctrl-r true
fi
```

---

### `zdot_module_list`

List all loaded modules with their source directories.

```zsh
zdot_module_list
```

Modules from the built-in dir are labelled "(modules)"; user-supplied modules
show their directory path.

---

### `zdot_module_dir`

Get the directory of the currently-loading module.

```zsh
zdot_module_dir
```

Sets `REPLY` to the module's directory path. Must be called from within a module
file (typically in the module's `.zsh` file).

**Example:**

```zsh
# Inside modules/fzf/fzf.zsh
zdot_module_dir
local my_dir="$REPLY"
source "${my_dir}/helpers.zsh"
```

---

### `zdot_module_source`

Source a file relative to the calling module.

```zsh
zdot_module_source <relative-path>
```

Compiles to `.zwc` if caching is enabled. Uses `zdot_module_dir` to resolve the
base directory.

**Example:**

```zsh
# Inside a module file
zdot_module_source "extra-config.zsh"
```

---

### `zdot_module_autoload_funcs`

Autoload functions from the calling module's `functions/` directory.

```zsh
zdot_module_autoload_funcs [function-names...]
```

If no names are given, autoloads all files in the module's `functions/` directory
(excluding `_*` completion functions, which are discovered by `compinit` via
fpath). Adds the directory to fpath and compiles files if caching is enabled.

**Example:**

```zsh
# Autoload all functions in this module's functions/ dir
zdot_module_autoload_funcs

# Autoload specific functions only
zdot_module_autoload_funcs fzf_fd fzf_rg
```

---

### `zdot_autoload_global_funcs`

Autoload functions from the global functions directory
(`${XDG_CONFIG_HOME}/zsh/functions`).

```zsh
zdot_autoload_global_funcs [function-names...]
```

Same behavior as `zdot_module_autoload_funcs` but uses the global functions
directory.

---

## Plugin Management

### `zdot_use_plugin`

Declare a plugin and optionally register a load hook.

```zsh
zdot_use_plugin <spec> [subcommand] [flags...]
```

| Parameter | Description |
|-----------|-------------|
| `<spec>` | Plugin spec: `user/repo`, `user/repo@version`, or bundle prefix like `omz:plugins/git`, `pz:modules/git` |

**Subcommands:**

| Subcommand | Description |
|------------|-------------|
| `hook` | Register an eager hook to load this plugin |
| `defer` | Register a deferred hook to load this plugin |
| `defer-prompt` | Register a deferred hook with prompt refresh |

| Flag | Argument | Valid With | Description |
|------|----------|------------|-------------|
| `--name` | `<n>` | hook, defer | Hook name label |
| `--provides` | `<p>` | hook, defer | Phase provided on load |
| `--config` | `<fn>` | hook, defer | Config function called before loading |
| `--context` | `<ctx...>` | hook, defer | Contexts (default: `interactive noninteractive`) |
| `--requires` | `<r>` | defer | Required phase |
| `--group` | `<g>` | hook, defer | Add hook to a named group (may repeat) |
| `--requires-group` | `<g>` | hook, defer | Require all hooks in the named group |
| `--provides-group` | `<g>` | hook, defer | Provide into the named group |

**Examples:**

```zsh
# Eager load with a dependency
zdot_use_plugin "zsh-users/zsh-completions" hook \
  --requires plugins-cloned \
  --provides zsh-completions-loaded

# Deferred load
zdot_use_plugin "zsh-users/zsh-autosuggestions" defer \
  --name autosuggestions

# OMZ plugin
zdot_use_plugin "omz:plugins/git" defer

# Prezto module (shorthand)
zdot_use_pz git
```

---

### `zdot_use_pz`

Convenience wrapper to declare a Prezto module.

```zsh
zdot_use_pz <module>
```

Equivalent to `zdot_use_plugin "pz:modules/<module>"`.

---

### `zdot_use_bundle`

Register a repository as a bundle dependency (not a user plugin).

```zsh
zdot_use_bundle <repo>
```

Prevents `zdot_clean_plugins` from treating it as orphaned.

---

### `zdot_register_bundle`

Register a custom bundle handler.

```zsh
zdot_register_bundle <name> [--init-fn <fn>] [--provides <phase>]
```

The handler must implement `zdot_bundle_<name>_match`, `_path`, `_clone`, and
`_load` functions.

---

### `zdot_plugin_clone`

Clone a single plugin repository.

```zsh
zdot_plugin_clone <spec>
```

Clones from GitHub. Supports version pinning via `@version`. Delegates to bundle
handlers if applicable. Skips if already cloned.

---

### `zdot_plugins_clone_all`

Clone all declared plugin repositories.

```zsh
zdot_plugins_clone_all
```

Uses a sentinel-file fast path: if specs haven't changed and all directories
exist, returns immediately.

---

### `zdot_load_plugin`

Load a plugin by sourcing its `*.plugin.zsh` file.

```zsh
zdot_load_plugin <spec>
```

Handles deduplication, bundle handler delegation, fpath addition for `functions/`
subdirectories, and optional bytecode compilation.

---

### `zdot_plugin_path`

Resolve a plugin spec to its filesystem path.

```zsh
zdot_plugin_path <spec>
```

Sets `REPLY` to the filesystem path.

---

### `zdot_plugin_compile`

Compile a plugin's `.zsh` files to `.zwc` bytecode.

```zsh
zdot_plugin_compile <spec>
```

---

### `zdot_plugin_compile_extra`

Register extra files to compile alongside a plugin.

```zsh
zdot_plugin_compile_extra <spec> <file> [<file> ...]
```

**Example:**

```zsh
zdot_plugin_compile_extra "lukechilds/zsh-nvm" "${NVM_DIR}/nvm.sh"
```

---

### `zdot_compile_plugins`

Compile all declared plugins.

```zsh
zdot_compile_plugins
```

---

### `zdot_plugins_have_changed`

Check if any git-sourced plugin has a new HEAD.

```zsh
zdot_plugins_have_changed
```

Returns 0 if changed, 1 if unchanged.

---

## Deferred Execution

These functions schedule commands to run after shell startup via `zsh-defer`.
When defer is disabled, commands execute immediately.

### `zdot_defer`

Schedule a command for post-startup execution.

```zsh
zdot_defer [flags] <command...>
```

| Flag | Description |
|------|-------------|
| `-q` / `--quiet` | Suppress precmd hooks and zle reset-prompt |
| `-p` / `--prompt` | Enable prompt refresh after the command |
| `--label <text>` | Human-readable label (visible in `zdot show defer-queue`) |

**Example:**

```zsh
zdot_defer eval "$(pyenv init -)"
zdot_defer --label "rbenv init" eval "$(rbenv init -)"
```

---

### `zdot_defer_until`

Schedule a command with a configurable delay.

```zsh
zdot_defer_until [flags] <delay> <command...>
```

| Parameter | Description |
|-----------|-------------|
| `<delay>` | Delay in seconds |

Flags are the same as `zdot_defer`.

**Example:**

```zsh
zdot_defer_until 2 zdot_cache_compile_all
```

---

## Platform & Context

### `zdot_is_macos`

Returns 0 on macOS, 1 otherwise.

```zsh
if zdot_is_macos; then
  # macOS-specific setup
fi
```

---

### `zdot_is_debian`

Returns 0 on Debian or Debian-derived distros, 1 otherwise.

```zsh
if zdot_is_debian; then
  zdot_load_module apt
fi
```

---

### `zdot_is_platform`

Test against one or more platform names or `$OSTYPE` globs.

```zsh
zdot_is_platform <name...>
```

Friendly aliases: `mac` -> `darwin*`, `linux` -> `linux*`, `debian` -> Debian
check. Raw globs also accepted (e.g. `darwin*`, `linux-gnu*`).

**Example:**

```zsh
if zdot_is_platform mac; then
  # macOS
elif zdot_is_platform debian; then
  # Debian/Ubuntu
fi
```

---

### `zdot_interactive`

Returns 0 if the current shell is interactive.

```zsh
zdot_interactive && echo "Interactive shell"
```

---

### `zdot_login`

Returns 0 if the current shell is a login shell.

```zsh
zdot_login && echo "Login shell"
```

---

### `zdot_has_tty`

Returns 0 if stdout is attached to a TTY.

```zsh
zdot_has_tty && echo "Has TTY"
```

> **Note:** Distinct from `zdot_interactive`. A shell can be interactive without
> a PTY (e.g. `zsh -i -c ...`).

---

### `zdot_variant`

Print the active variant name.

```zsh
local v="$(zdot_variant)"
```

---

### `zdot_is_variant`

Test if the active variant matches a name.

```zsh
zdot_is_variant <name>
```

**Example:**

```zsh
if zdot_is_variant work; then
  zdot_load_module corporate-proxy
fi
```

---

### `zdot_resolve_variant`

Resolve the active variant. Priority: (1) `$ZDOT_VARIANT` env var,
(2) zstyle `:zdot:variant` `name`, (3) user-supplied `zdot_detect_variant()`
function.

```zsh
zdot_resolve_variant
```

> **Note:** Called automatically by `zdot_init`. Documented for completeness.

---

### `zdot_build_context`

Build the full shell context string (interactive/login/variant).

```zsh
zdot_build_context
```

> **Note:** Called automatically by `zdot_init`. Documented for completeness.

---

## Logging

All logging functions accept one or more message arguments. Messages are printed
to stdout unless noted otherwise.

### Output Functions

| Function | Color | Stream | Suppressed in Quiet Mode? | Requires Flag? |
|----------|-------|--------|--------------------------|----------------|
| `zdot_info <msg>` | default | stdout | Yes | -- |
| `zdot_info_nonl <msg>` | default | stdout | Yes | -- |
| `zdot_success <msg>` | green | stdout | Yes | -- |
| `zdot_report <msg>` | cyan | stdout | Yes | -- |
| `zdot_action <msg>` | blue | stdout | Yes | -- |
| `zdot_error <msg>` | red | stderr | **No** (always shown) | -- |
| `zdot_warn <msg>` | yellow | stderr | **No** (always shown) | -- |
| `zdot_verbose <msg>` | cyan | stdout | -- | `$ZDOT_VERBOSE` or `$ZDOT_DEBUG` |
| `zdot_debug <msg>` | magenta | stderr | -- | `$ZDOT_DEBUG` |
| `zdot_log_debug <msg>` | magenta | stdout | -- | `$ZDOT_DEBUG` |

**Quiet mode** is enabled via:

```zsh
zstyle ':zdot:logging' quiet true
```

**Verbose/debug mode** is enabled via environment variables:

```zsh
ZDOT_VERBOSE=1 zsh     # verbose + normal output
ZDOT_DEBUG=1 zsh       # debug + verbose + normal output
```

`zdot_info_nonl` prints without a trailing newline (for progress indicators).
In deferred context, it falls back to a normal line to avoid dropped output.

---

### Utility Functions

| Function | Description |
|----------|-------------|
| `zdot_show_deferred_log` | Replay accumulated deferred log messages |
| `zdot_cleanup_logging` | Unset all logging variables and functions (teardown) |

---

## Cache

zdot implements a two-tier cache:
- **Tier 1:** `.zwc` bytecode compilation (co-located alongside source files)
- **Tier 2:** Execution plan serialization (context-specific cache files)

### `zdot_cache_init`

Initialize the cache system.

```zsh
zdot_cache_init
```

Reads configuration from zstyle:

```zsh
zstyle ':zdot:cache' enabled true             # default: true
zstyle ':zdot:cache' directory "$XDG_CACHE_HOME/zdot"  # default
```

> **Note:** Called automatically during zdot bootstrap. Documented for
> completeness.

---

### `zdot_cache_is_enabled`

Returns 0 if caching is enabled.

```zsh
if zdot_cache_is_enabled; then
  zdot_cache_compile_file "$my_file"
fi
```

---

### `zdot_cache_compile_file`

Compile a single zsh file to `.zwc` bytecode.

```zsh
zdot_cache_compile_file <source-file>
```

Creates the `.zwc` file alongside the source. Skips if already up to date.

---

### `zdot_cache_compile_all`

Compile all core modules and loaded modules to bytecode.

```zsh
zdot_cache_compile_all
```

---

### `zdot_cache_compile_functions`

Compile all files in a function directory.

```zsh
zdot_cache_compile_functions <func-dir> [glob-pattern]
```

| Parameter | Description |
|-----------|-------------|
| `<func-dir>` | Directory containing function files |
| `[glob-pattern]` | Pattern for files to compile (default: `*`) |

---

### `zdot_cache_save_plan`

Serialize the current execution plan to a cache file.

```zsh
zdot_cache_save_plan
```

> **Note:** Called automatically by `zdot_init`. Documented for completeness.

---

### `zdot_cache_invalidate`

Invalidate all caches (execution plans, `.zwc` files, compdump metadata,
plugin stamps).

```zsh
zdot_cache_invalidate
```

Also available via CLI: `zdot cache invalidate`.

---

### `zdot_cache_stats`

Display cache statistics.

```zsh
zdot_cache_stats
```

Also available via CLI: `zdot cache stats`.

---

### `zdot_cache_create_dirs`

Create the cache directory structure.

```zsh
zdot_cache_create_dirs
```

---

## Completions

### `zdot_register_completion_file`

Register a completion to be generated by `refresh_completions`.

```zsh
zdot_register_completion_file <command> <generate-command> [dest-dir]
```

| Parameter | Description |
|-----------|-------------|
| `<command>` | Command name (e.g. `gh`) |
| `<generate-command>` | Shell command that produces the completion script |
| `[dest-dir]` | Destination directory (default: `$XDG_CACHE_HOME/zdot/completions`) |

**Example:**

```zsh
zdot_register_completion_file gh "gh completion -s zsh"
zdot_register_completion_file docker "docker completion zsh"
```

---

### `zdot_register_completion_live`

Register a function to run live during init for completion setup.

```zsh
zdot_register_completion_live <function-name>
```

---

### `zdot_get_completions_dir`

Print the completions directory path to stdout.

```zsh
local dir="$(zdot_get_completions_dir)"
```

---

## Utilities

### `zdot_add_fpath`

Add a directory to `fpath`.

```zsh
zdot_add_fpath <dir> [--glob <pattern>]
```

Prepends `<dir>` to fpath. If caching is enabled, compiles files matching the
glob pattern to `.zwc`.

**Example:**

```zsh
zdot_add_fpath "${ZDOT_DIR}/my-completions" --glob "*.zsh"
```

---

### `zdot_include_source`

Source a file or directory, compiling first if caching is enabled.

```zsh
zdot_include_source <path> [--glob <pattern>]
```

If `<path>` is a file, compiles and sources it. If a directory, compiles and
sources all files matching the glob (default: `*.zsh`).

**Example:**

```zsh
zdot_include_source "${my_module_dir}/extras"
zdot_include_source "${my_module_dir}/init.zsh"
```

---

### `zdot_verify_tools`

Runtime check that tools are available on PATH.

```zsh
zdot_verify_tools <tool1> [tool2 ...]
```

Emits a warning for each tool not found. Does not affect scheduling.

**Example:**

```zsh
zdot_verify_tools git curl jq
```

---

### `zdot_verify_tools_zstyle`

Read a tool list from zstyle and verify each exists.

```zsh
zdot_verify_tools_zstyle <zstyle-context> <default-tool...>
```

Falls back to the default list if the zstyle is unset.

---

### `zdot_provides_tool_args`

Build `--provides-tool` arguments from a zstyle tool list.

```zsh
zdot_provides_tool_args <zstyle-context> <default-tool...>
```

Sets `reply` array with `--provides-tool <tool>` pairs, suitable for splatting
into `zdot_register_hook` or `zdot_simple_hook`.

**Example:**

```zsh
zdot_provides_tool_args ':zdot:module:brew' brew
zdot_simple_hook brew "${reply[@]}"
```

---

### `zdot_zstyle_default`

Seed a zstyle default only when the style isn't already set for the context.

```zsh
zdot_zstyle_default [-e] <context> <style> <value> [<value>...]
```

Lets a module define backstop defaults that any user-set value transparently
overrides — whether set in `.zshrc`, a [`zdot_before_module`](#zdot_before_module)
callback (parse-time), or a `*-configure` group hook (DAG-time). If the user
already set the style, the default is skipped; otherwise it's applied.

Presence is tested with `zstyle -g`, so it works regardless of how the style is
later read (`-s`/`-a`/`-b`/`-t`) and for array and `-e` (evaluated) styles alike.
Mirrors the zstyle *setting* syntax: pass `-e` for an evaluated default, and any
number of values after `<style>` for multi-valued styles.

**Example:**

```zsh
zdot_zstyle_default ':zsh-ai:*'        endpoint 'http://localhost:11434/v1'
zdot_zstyle_default ':zsh-ai:scratch'  enabled  yes
zdot_zstyle_default ':zsh-ai:scratch'  keybind  '^Xa'
zdot_zstyle_default -e ':completion:*' hosts    'reply=($myhosts)'
```

---

### `zdot_is_newer_or_missing`

Check if a source file is newer than a destination (or the destination is
missing).

```zsh
zdot_is_newer_or_missing <source> <dest>
```

Returns 0 if the source is newer or the destination does not exist.

---

### `zdot_init_short_host`

Initialize the `$SHORT_HOST` global variable.

```zsh
zdot_init_short_host
```

On macOS uses `scutil --get LocalHostName`; elsewhere uses `${HOST/.*/}`.

> **Note:** Runs automatically at source time.

---

## CLI

zdot provides an interactive CLI using a `<noun> <verb>` pattern:

```
zdot <noun> <verb> [args...]
```

| Noun | Verbs | Description |
|------|-------|-------------|
| `cache` | `invalidate`, `stats` | Cache management |
| `hook` | `list`, `status` | Hook introspection |
| `phase` | `list` | Phase introspection |
| `plugin` | `list`, `clean`, `remove`, `update`, `reclone` | Plugin management |
| `module` | `list`, `hooks` | Module introspection |
| `completion` | `refresh`, `dir` | Completion management |
| `secret` | `refresh` | 1Password secrets |
| `update` | `check`, `run` | Self-update |
| `info` | | Environment info |
| `debug` | | Debug diagnostics |
| `bench` | | Startup benchmark |
| `profile` | | zprof startup profile |
| `help` | | Show help |

Tab completion is available (via the `_zdot` completion function).

For full CLI documentation, see [commands.md](commands.md).
