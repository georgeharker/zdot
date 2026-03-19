# Plugin Implementation Details

## Architecture

The plugin system has three main components:

### 1. Core Plugin Manager (`core/plugins.zsh`)

Handles plugin declaration, cloning, and loading:

```
_ZDOT_PLUGINS_ORDER   - Array of declared plugin specs
_ZDOT_PLUGINS        - Associative array: spec -> kind (normal/defer/fpath/path)
_ZDOT_PLUGINS_LOADED - Associative array: spec -> 1 (if loaded)
_ZDOT_PLUGINS_CACHE  - Cache directory path
```

**Key Functions:**

| Function | Purpose |
|----------|---------|
| `zdot_use_plugin <spec> [-hook\|-defer] [opts]` | Declare a plugin (normal, hook-loaded, or deferred) |
| `zdot_use_defer <spec>` | **Deprecated** — alias for `zdot_use_plugin <spec> -defer` |
| `zdot_use_fpath <spec>` | Declare plugin with fpath kind (legacy compat) |
| `zdot_use_path <spec>` | Declare plugin with path kind (legacy compat) |
| `zdot_init` | Clone all repos, run bundle inits, resolve groups, build DAG, execute all hooks |
| `zdot_plugin_path <spec>` | Get filesystem path for plugin |
| `zdot_plugin_clone <spec>` | Clone plugin to cache |
| `zdot_plugins_clone_all` | Clone all declared plugins |
| `zdot_load_plugin <spec>` | Load a specific plugin |
| `zdot_list_plugins [--mode]` | List plugins |
| `zdot_update_plugin [spec]` | Update plugin(s) |
| `zdot_clean_plugins` | Remove unused plugins |
| `zdot_import_antidote [file]` | Import antidote-style config |

**Plugin Spec Formats:**

| Format | Example | Description |
|--------|---------|-------------|
| External | `user/repo` | GitHub repo |
| External with version | `user/repo@v1.0.0` | GitHub repo at specific tag/branch |
| OMZ plugin | `omz:plugins/git` | Plugin from ohmyzsh |
| OMZ lib | `omz:lib` | Library from ohmyzsh |

### 2. Hook System (`core/hooks.zsh`)

Provides phase-based execution:

```
xdg-configured          -> XDG dirs configured
plugins-cloned          -> Plugins cloned to cache
omz-lib-loaded          -> OMZ lib sourced
omz-plugins-loaded      -> OMZ plugins individually loaded
abbr-ready              -> zsh-abbr loaded
fsh-ready               -> fast-syntax-highlighting loaded
fast-abbr-ready         -> fast-abbr bridge loaded
autosuggest-ready       -> zsh-autosuggestions loaded
autosuggest-abbr-ready  -> autosuggest-abbr bridge loaded (last deferred phase)
compinit-done           -> compinit has run (interactive only)
fzf-tab-loaded          -> fzf-tab loaded (interactive only)
plugins-post-configured -> Post-load config done
nvm-ready               -> NVM initialized
                           (interactive: triggered after plugins-post-configured;
                            noninteractive: triggered after omz-plugins-loaded)
```

Registration:
```zsh
zdot_register_hook my_func interactive \
    --requires plugins-declared \
    --provides plugins-loaded
```

### 3. Plugin Bundles (`core/plugin-bundles/`)

Domain-specific plugin handling via a registry. Each bundle handler is a self-contained
file that registers itself with the core plugin manager at source time.

**Registry state (in `core/plugins.zsh`):**

```
_ZDOT_BUNDLE_HANDLERS   - Ordered array of registered bundle handler names
```

**Registry API:**

| Function | Purpose |
|----------|---------|
| `zdot_register_bundle <name> [--init-fn <fn>] [--provides <phase>]` | Register a bundle handler |

**Currently registered handlers:**

- `omz` (`omz.zsh`) — Oh My Zsh compatibility

#### Bundle Handler Interface Contract

Every bundle handler must implement exactly four functions. All take a single `<spec>`
argument (e.g., `omz:plugins/git`):

```zsh
zdot_bundle_<name>_match <spec>   # Return 0 if this handler owns spec; non-zero otherwise
zdot_bundle_<name>_path  <spec>   # Print the filesystem path for spec
zdot_bundle_<name>_clone <spec>   # Ensure plugin is on disk (may be a no-op)
zdot_bundle_<name>_load  <spec>   # Source / activate the plugin
```

All four functions are required. If a handler does not need cloning (e.g., OMZ is
cloned at file-source time), `zdot_bundle_<name>_clone` must still be defined as a no-op.

Optionally, a handler may also define an init function that is called by `zdot_init`
during its bundle-init pass (step 2), **before** any plugins are cloned or loaded:

```zsh
zdot_bundle_<name>_init()  {
    # one-time setup: set environment vars, configure paths, etc.
}
```

Registration must happen **after** all four (or five) functions are defined, at the end
of the file, and must declare any init function and phase it provides:

```zsh
zdot_register_bundle <name> [--init-fn zdot_bundle_<name>_init] [--provides <phase>]
```

`zdot_register_bundle` is idempotent — sourcing the file twice is safe.

#### Writing a New Bundle Handler

Create `core/plugin-bundles/<name>.zsh` with the following skeleton:

```zsh
# Match any spec this handler owns
zdot_bundle_<name>_match() {
    [[ $1 == <name>:* ]]
}

# Return the filesystem path for a spec
zdot_bundle_<name>_path() {
    local spec=$1
    # derive and print path
}

# Ensure the plugin is available on disk
zdot_bundle_<name>_clone() {
    local spec=$1
    # clone / install if not present; or leave empty if not needed
}

# Load (source/activate) the plugin
zdot_bundle_<name>_load() {
    local spec=$1
    # source the plugin entry point
}

zdot_register_bundle <name> [--init-fn zdot_bundle_<name>_init] [--provides <phase>]
```

Then explicitly source the new file in `zdot.zsh` (auto-discovery is a planned future
enhancement — see "Spec Format Decision" below).

#### Spec Format Decision

The `omz:xxx` spec format is kept **unchanged** (e.g., `omz:plugins/git`, `omz:lib`).
A `bundle:omz:xxx` prefix was considered and rejected: it would break all existing user
configs with no practical benefit, because the registry already handles dispatch
transparently via `zdot_bundle_omz_match`. See the "Plugin Spec Formats" table above for
all supported formats.

## Plugin Bundle (`core/plugin-bundles/omz.zsh`)

### Compdef Queue

Before `compinit` runs, bare `compdef` calls (e.g. from OMZ plugins) are
intercepted by a stub function and queued. After `compinit` runs, the stub is
removed and the queue is replayed using the real `compdef` defined by
`compinit`.

OMZ plugins call `compdef` directly; no wrapper is needed:

```zsh
# OMZ plugins call compdef directly — the stub queues it automatically
compdef _git git
# Later replayed by zdot_compdef_queue_process after compinit
```

### Two-Phase Compinit Flow

Completions require a careful ordering: all plugins must add to `$fpath` before
`compinit` runs, but `compinit` must not block startup. The solution is a
two-phase approach with a compdef stub queue.

#### Phase 1 — Compdef stub (sourced immediately)

A `compdef()` stub is installed at source time. When plugins call `compdef`
before `compinit` has run, the stub queues the call in `_ZDOT_COMPDEF_QUEUE`
instead of executing it. In non-interactive shells the stub is a no-op:

```zsh
compdef() {
    zdot_interactive || return 0
    _compdef_queue "$@"          # append to _ZDOT_COMPDEF_QUEUE
}
```

#### Phase 2a — fpath accumulation + deferred signal

After all deferred plugins are loaded (and have added their dirs to `$fpath`),
`zdot_compinit_defer` is called via `zdot_defer`. Its only job is to set the
`_ZDOT_FPATH_READY=1` flag — it never calls `compinit` directly (doing so
inside `zsh-defer` would cause a hang):

```zsh
zdot_compinit_defer() {
    zdot_interactive || return 0
    _ZDOT_FPATH_READY=1
}
```

#### Phase 2b — precmd hook triggers compinit

`zdot_ensure_compinit_during_precmd` is registered as a `precmd` hook. On each
prompt draw it checks both conditions, then runs `zdot_compinit_run` exactly
once:

```zsh
zdot_ensure_compinit_during_precmd() {
    (( _ZDOT_COMPINIT_DONE )) && { _zdot_remove_precmd_hook; return 0 }
    (( _ZDOT_FPATH_READY  )) || return 0   # not ready yet — try next precmd
    zdot_compinit_run
}
```

#### `zdot_compinit_run` — the critical step

**`unfunction compdef` MUST precede `compinit`.**  If the stub is still defined
when `compinit` runs, zsh sees an existing `compdef` and silently skips
redefining it — leaving only the stub, which can only queue and never register
completions.

```zsh
zdot_compinit_run() {
    unfunction compdef 2>/dev/null   # remove stub BEFORE compinit
    if zdot_compdump_needs_refresh; then
        compinit -i                  # full init, refresh compdump
    else
        compinit -C                  # fast path, trust cached compdump
    fi
    zdot_compdef_queue_process       # replay all queued compdef calls
    _ZDOT_COMPINIT_DONE=1
}
```

#### Queue replay

After `compinit` defines the real `compdef`, all queued entries are replayed:

```zsh
zdot_compdef_queue_process() {
    local entry
    for entry in "${_ZDOT_COMPDEF_QUEUE[@]}"; do
        compdef "${(@Q)${(z)entry}}"
    done
    _ZDOT_COMPDEF_QUEUE=()
}
```

**Key ordering constraint**: stub removal → `compinit` → queue replay. Deviating
from this order silently breaks tab completions.

### Compdump Management

```zsh
zdot_compdump_needs_refresh  # Returns exit code if refresh needed
zdot_has_zcompdump_expired   # Check if expired
```

### Theme Loading

Loads OMZ themes during precmd (matches antidote behavior):
- Only loads if `ZSH_THEME` is set
- Provides `omz-theme-ready` phase

### Lazy Library Loading

OMZ libraries are lazy-loaded via function stubs:

```zsh
function git_prompt_info {
    zdot_omz_lazy_load_lib git.zsh
    "$0" "$@"
}
```

**Lazy-loaded libraries:**
- compfix.zsh
- completion.zsh
- correction.zsh
- diagnostics.zsh
- functions.zsh
- git.zsh
- grep.zsh
- nvm.zsh
- theme-and-appearance.zsh
- clipboard.zsh
- spectrum.zsh

## Phase Contract

The zdot plugin system uses a single trigger model: user-land declares all plugin
specs via `zdot_use_plugin` calls, then calls `zdot_init` exactly once.  `zdot_init` drives
the entire clone-and-load sequence internally; no user-land hook is required to emit
any intermediate phase.

### `zdot_init` — the single trigger

`zdot_init` must be called **after** all `zdot_use_plugin` declarations in the same file
(or after sourcing all sub-modules that contain `zdot_use_plugin` calls).  It performs five
steps in order:

1. Clone all repos that have not yet been cloned (`zdot_plugins_clone_all`).
2. Run the init function for every registered bundle handler that declared `--init-fn`.
3. Resolve group annotations (`--group`, `--provides-group`, `--requires-group`) into
   concrete DAG edges.
4. Build the hook execution plan (topological sort of registered hooks).
5. Execute all hooks in plan order, respecting `--deferred` and interactivity flags.

### `plugins-cloned` — emitted by core

After step 1 completes, core emits `plugins-cloned`.  Every hook that loads or
configures plugins must declare `--requires plugins-cloned` so it runs only after
the filesystem is ready.

### Summary

| Phase             | Provided by        | Consumed by                        |
|-------------------|--------------------|------------------------------------|
| `plugins-cloned`  | `zdot_init` step 1 | every plugin-loading hook           |

The core clone hook registration lives in `core/plugins.zsh`.  `zdot_init` is called
at the bottom of the user's `.zshrc` (after all `zdot_use_plugin` declarations).

---

## Plugin Loading Flow

```
Shell startup (.zshrc / .zshenv):
  └─> modules sourced (modules/plugins/, modules/fzf/, modules/nodejs/, etc.
       │   via zdot_load_module calls)
       └─> zdot_use_plugin / zdot_use_plugin hook / zdot_use_plugin defer calls register specs
           and hook functions against named phases
       └─> zdot_init called at end of .zshrc

zdot_init (core/init.zsh):
  1. zdot_plugins_clone_all        — clone all repos; emits plugins-cloned
  2. bundle init pass              — calls zdot_bundle_omz_init (provides: omz-lib-loaded)
     NOTE: The former monolithic plugins.zsh has been split into
           per-concern modules (autocompletion, fzf, nodejs, shell-extras, tmux).
  3. resolve group annotations     — injects edges for --group/--provides-group/--requires-group
  4. build execution plan          — topological sort of registered hooks
  5. execute all hooks in order

Hook phase chain (driven by zdot_init step 5):
  xdg-configured
    └─> _plugins_configure         (requires: xdg-configured)
  plugins-cloned
    └─> _plugins_load_omz          (requires: plugins-cloned)
                                   (provides: omz-plugins-loaded)
                                   (calls zdot_load_plugin per OMZ spec)
  omz-plugins-loaded
    └─> olets/zsh-abbr             (deferred; provides: abbr-ready)
    └─> zsh-users/zsh-autosuggestions
                                   (deferred; provides: autosuggest-ready)
    └─> zdharma-continuum/fast-syntax-highlighting
                                   (deferred; provides: fsh-ready)
    └─> _nvm_noninteractive_init   (noninteractive only; provides: nvm-ready)
  fsh-ready
    └─> 5A6F65/fast-abbr           (deferred; provides: fast-abbr-ready)
  autosuggest-ready
    └─> olets/zsh-autosuggestions-abbreviations-strategy
                                   (deferred; provides: autosuggest-abbr-ready)
  autosuggest-abbr-ready
    └─> zdot_compinit_defer        (deferred; provides: compinit-done)
    └─> _plugins_load_fzf_tab      (interactive only; provides: fzf-tab-loaded)
    └─> _plugins_post_init         (deferred; provides: plugins-post-configured)
  plugins-post-configured
    └─> _nvm_interactive_init      (interactive, deferred; provides: nvm-ready)
```

## Non-Interactive Mode Handling

The plugin system handles non-interactive shells gracefully:

1. **Compinit** - `zdot_compinit_defer` returns early in non-interactive:
   ```zsh
   zdot_interactive || return 0
   ```

2. **fzf module** - Early exit in non-interactive:
   ```zsh
   zdot_interactive && (( ${+zle} )) || return 0
   ```

3. **NVM** - Uses `nvm use node >/dev/null` (silent) in non-interactive

This prevents errors like:
```
(eval):1: can't change option: zle
```

## Cache Location

All caches in `~/.cache/zdot/`:

| Path | Purpose |
|------|---------|
| `plugins/` | Cloned plugin repositories |
| `plugins/ohmyzsh/ohmyzsh` | OMZ core |
| `plugins/romkatv/zsh-defer` | zsh-defer |
| `plugins/<org>/<repo>` | Third-party plugins |
| `cache/zwc/` | Compiled function caches |
| `completions/` | Completion caches |

## Plugin Discovery

To find which plugins are used across your config:

1. **Declared** (via `zdot_use_plugin`): `_ZDOT_PLUGINS_ORDER` array
2. **Loaded** (actually used): `_ZDOT_PLUGINS_LOADED` associative array
3. **Installed** (in cache): iterate `$ZDOT_PLUGINS_CACHE/*`

## Debugging

```bash
# List all declared plugins
zdot_list_plugins --declared

# List what's actually loaded
zdot_list_plugins --loaded

# List what's in cache
zdot_list_plugins --installed

# Update all plugins
zdot_update_plugin

# See what would be cleaned
zdot_clean_plugins --dry-run
```

## Differences from Antidote

| Feature | Antidote | Zdot |
|---------|----------|------|
| Plugin declaration | `plugins=(...)` or separate file | `zdot_use_plugin` in modules |
| OMZ support | Built-in | Via `omz:` prefix |
| Raw OMZ format | Via separate file | Via `zdot_import_antidote` |
| Library loading | All at once | Lazy via stubs |
| Cache location | `~/.cache/antidote/` | `~/.cache/zdot/` |
| Theme loading | During init | During precmd |
| Phase system | Built-in | Custom hooks |

**Raw OMZ Format Support:**

Zdot can import antidote's raw `plugins=(...)` format:

```zsh
# Import from antidote config file
zdot_import_antidote

# Or manually use the format in your modules:
# Compatible with:
#   ohmyzsh/ohmyzsh path:lib
#   ohmyzsh/ohmyzsh path:plugins/git
#   olets/zsh-abbr kind:defer
```
