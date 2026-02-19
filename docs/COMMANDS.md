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
| `hook` | `list [-v] [-a]`, `plan` |
| `plugin` | `list [--loaded\|--installed\|--declared]`, `update [spec]`, `clean [--dry-run] [--remove-unused]`, `reclone` |
| `module` | `list` |
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
```

**Implementation**: delegates to `zdot_hooks_list` and `zdot_show_plan` (core/hooks.zsh).

---

## plugin

Plugin lifecycle management.

```
zdot plugin list [--loaded|--installed|--declared]
  # List plugins. Default: all declared plugins.
  # --loaded     Show only plugins successfully loaded this session
  # --installed  Show only plugins with a local directory on disk
  # --declared   Show only plugins registered via zdot_plugin_declare

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

Module inspection.

```
zdot module list   # List all loaded modules and their status
```

**Implementation**: delegates to `zdot_module_list` (core/modules.zsh).

---

## completion

Shell completion management.

```
zdot completion refresh   # Regenerate completion files for all registered tools
```

**Implementation**: delegates to `refresh_completions` (core/completions.zsh).

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
- Key paths: `$_ZDOT_BASE_DIR`, `$_ZDOT_LIB_DIR`, `$_ZDOT_CACHE_DIR`
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
- `_ZDOT_PHASES_PROVIDED` / `_ZDOT_PHASES_PROMISED` — phase lifecycle state
- `_ZDOT_PLUGINS_ORDER` — all declared plugins with loaded/not-loaded status
- `_ZDOT_MODULES_LOADED` — all loaded modules

---

## bench

Run the shell startup benchmark script.

```
zdot bench [args...]   # Runs scripts/benchmark.zsh; extra args are forwarded
```

---

## profile

Run the shell startup profiler.

```
zdot profile [args...]   # Runs scripts/profile.zsh; extra args are forwarded
```

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
