# zdot CLI Reference

`zdot` is the management CLI for the zdot plugin framework. It uses a **noun + verb** dispatch model:

```
zdot <noun> <verb> [options...]
```

Tab-completion is provided automatically via `_zdot` (registered at startup with `compdef _zdot zdot`).

---

## Quick reference

| Noun | Verbs |
|------|-------|
| `cache` | `status`, `invalidate`, `compile` |
| `hook` | `list [-v] [-a]`, `plan`, `graph [--depends\|--uses\|--all]` |
| `plugin` | `list [--loaded\|--installed\|--declared]`, `update [spec]`, `clean [--dry-run] [--remove-unused]`, `reclone` |
| `module` | `list`, `clone <name>` |
| `completion` | `refresh` |
| `secret` | `refresh` |
| `info` | *(no verb)* |
| `debug` | *(no verb)* |
| `bench` | *(no verb)* |
| `profile` | *(no verb)* |
| `help` | `[noun]` |

Every noun also accepts `help` or `--help` as a verb.

---

## cache

Cache management for compiled function files.

```
zdot cache status      # Show cache stats and hit/miss counts
zdot cache invalidate  # Invalidate all cached files
zdot cache compile     # Recompile all autoloaded function files
```

**Implementation**: delegates to `zdot_cache_stats`, `zdot_cache_invalidate`, `zdot_cache_compile_all` (core/cache.zsh).

---

## hook

Hook and execution-plan inspection.

```
zdot hook list [-v] [-a]   # List registered hooks
  -v, --verbose             Show full hook metadata (requires, provides, contexts, optional)
  -a, --all                 Include hooks from all contexts (not just current)

zdot hook plan             # Print the full execution plan in dependency order

zdot hook graph --depends <name>   # ASCII tree: what <name> requires (recursive)
zdot hook graph --uses <name>      # ASCII tree: what depends on <name> (recursive)
zdot hook graph --all              # Full dependency graph for all hooks
```

**Implementation**: delegates to `zdot_hooks_list`, `zdot_show_plan`, and `zdot_hooks_graph` (core/hooks.zsh).

---

## plugin

Plugin lifecycle management.

```
zdot plugin list [--loaded|--installed|--declared]
  # List plugins. Default: all declared plugins.
  # --loaded     Show only plugins successfully loaded this session
  # --installed  Show only plugins with a local directory on disk
  # --declared   Show only plugins registered via zdot_use_plugin

zdot plugin update [spec]
  # Update one or all plugins.
  # spec: optional plugin spec (e.g. "zsh-users/zsh-syntax-highlighting")
  # No spec: updates all declared plugins.

zdot plugin clean [--dry-run] [--remove-unused]
  # Remove stale plugin directories.
  # --dry-run        Show what would be removed without deleting anything
  # --remove-unused  Also remove directories for plugins not declared anywhere

zdot plugin reclone
  # Delete and re-clone all declared plugins from scratch.
```

**Implementation**: delegates to `zdot_list_plugins`, `zdot_update_plugin`, `zdot_clean_plugins`, `zdot_reclone_plugins` (core/plugins.zsh).

---

## module

Module inspection and management.

```
zdot module list           # List all loaded modules with their source directory
zdot module clone <name>   # Copy a module to the first user directory in the search path
```

`clone` finds the module via the search path (user directories first, then `modules/`) and
copies it into the first non-`modules/` directory in the search path as a starting point
for local customisation. Fails if the destination already exists.

**Implementation**: delegates to `zdot_module_list` and the `clone` dispatch block
in `core/functions/zdot`.

---

## completion

Shell completion management.

```
zdot completion refresh           # Lazy: regenerate only stale or missing completions
zdot completion refresh --force   # Force: regenerate all completions unconditionally
```

Default (lazy) mode skips tools whose completion file is newer than the resolved binary.
`--force` always regenerates and warns if any registered command is not found.

**Implementation**: delegates to `refresh_completions` (`modules/completions/functions/refresh_completions`).

---

## secret

Secret management.

```
zdot secret refresh   # Pull latest secrets from 1Password into the shell environment
```

**Implementation**: delegates to `refresh_shell_secrets`.

---

## info

Print environment and runtime state. Takes no verb.

```
zdot info
```

**Output includes:**
- Key paths: `$ZDOT_DIR`, `$_ZDOT_MODULE_DIR`, `$_ZDOT_CACHE_DIR`
- Shell context: `$_ZDOT_IS_INTERACTIVE`, `$_ZDOT_IS_LOGIN`
- Cache config: enabled flag, version string
- Counts: plugins declared/loaded, hooks registered/executed, modules loaded

---

## debug

Dump full internal state. Takes no verb.

```
zdot debug
```

**Output includes:**
- `_ZDOT_EXECUTION_PLAN` — ordered list of hook IDs in dependency-resolved order
- `_ZDOT_HOOKS_EXECUTED` — hooks that have run this session
- `_ZDOT_PHASES_PROVIDED` — phase lifecycle state
- `_ZDOT_PLUGINS_ORDER` — all declared plugins with loaded/not-loaded status
- `_ZDOT_MODULES_LOADED` — all loaded modules

---

## bench

Measure zsh startup time across all four shell contexts.

```
zdot bench [--compare] [ITERATIONS]
```

Zsh can be started in four different contexts depending on how it is invoked
and which dotfiles it sources.  `zdot bench` times all four:

| Context | zsh invocation | Dotfiles sourced |
|---|---|---|
| interactive non-login | `zsh -i` | `.zshenv`, `.zshrc` |
| interactive login | `zsh -il` | `.zshenv`, `.zprofile`, `.zshrc`, `.zlogin` |
| non-interactive non-login | `zsh` | `.zshenv` |
| non-interactive login | `zsh -l` | `.zshenv`, `.zprofile`, `.zlogin` |

Because zdot can bootstrap from `.zshenv`, `.zprofile`, or `.zshrc` depending
on how your dotfiles are structured, all four contexts are meaningful.

`ITERATIONS` (default: 20) controls how many timed runs are averaged per
variant.  Each variant also runs one warmup invocation first to ensure the
zdot startup cache is warm before timing begins.

**Default mode**: prints a summary table with mean, min, max, and stddev for
each of the four contexts.

**Comparison mode** (`--compare`): runs each context twice — once with
`ZDOT_OLD_SETUP=true` and once with `ZDOT_OLD_SETUP=false` — and reports a
percentage change and `new faster / new slower / same` verdict per context.
This requires your dotfiles to honour `ZDOT_OLD_SETUP` (see below).

Environment variables:

| Variable | Description |
|---|---|
| `ZDOTDIR` | Standard zsh variable. Cache-busting touches `$ZDOTDIR/.zshrc` (falls back to `$HOME/.zshrc`). |

### A/B comparison with `ZDOT_OLD_SETUP`

If your dotfiles have an old and a new setup that can be selected at startup
time, you can expose a `ZDOT_OLD_SETUP` variable that your dotfiles check.
For example, in your `.zshenv` or `.zshrc`:

```zsh
if [[ "${ZDOT_OLD_SETUP:-false}" == "true" ]]; then
    # source old plugin manager / config
else
    # source new setup
fi
```

Then run:

```zsh
zdot bench --compare
```

The benchmark will run all four contexts with both values of `ZDOT_OLD_SETUP`
and show the impact across every startup mode.

---

## profile

Profile zsh startup using `zprof` to identify which functions are slowest.

```
zdot profile [--warm]
```

Runs `scripts/profile.zsh`.  Creates a temporary `ZDOTDIR` containing a
wrapper `.zshrc` that loads `zprof` instrumentation before sourcing your real
`.zshrc`, then prints the function-level timing breakdown.

**`bench` vs `profile`**: `bench` measures *total* wall-clock startup time
with statistical rigour across multiple runs and contexts.  `profile` runs
*once* and shows a breakdown by function — it tells you *where* time is being
spent, not *how much* total time is used.  Use `bench` to track regressions
and compare setups; use `profile` to diagnose what to optimise.

Options:

| Flag | Description |
|---|---|
| `--warm` | Symlink existing compdump files into the temp dir so `compinit` is skipped, simulating a normal (non-first) startup |

To compare old vs new setups, set `ZDOT_OLD_SETUP` yourself and run twice:

```zsh
ZDOT_OLD_SETUP=true  zdot profile
ZDOT_OLD_SETUP=false zdot profile
```

Environment variables:

| Variable | Description |
|---|---|
| `ZDOTDIR` | Respected automatically. The real `.zshrc` is sourced from `$ZDOTDIR/.zshrc` (falls back to `$HOME/.zshrc`). |
| `ZDOT_OLD_SETUP` | Passed through unchanged into the profiled shell. Set it in the environment before running if your dotfiles honour it. |

---

## help

Show help for the CLI or for a specific noun.

```
zdot help           # Show the top-level noun list
zdot help <noun>    # Show detailed help for a noun
zdot <noun> help    # Equivalent to 'zdot help <noun>'
zdot <noun> --help  # Equivalent to 'zdot help <noun>'
```

---

## Tab-completion

`_zdot` is a zsh completion function registered at startup:

```zsh
compdef _zdot zdot
```

It provides:
- **Word 2**: noun completions with descriptions
- **Word 3**: verb completions per noun
- **Word 4+**: flag completions for `hook list`, `plugin list`, and `plugin clean`
