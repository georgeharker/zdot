# Plugin Hook Architecture

**Status:** Design — not yet implemented
**Date:** 2026-02-22

---

## Background

The current plugin loading system has two layers that have drifted out of sync:

1. `core/plugins.zsh` — provides `zdot_use`, `zdot_use_defer`, `zdot_load_all_plugins`,
   `zdot_load_deferred_plugins`, and the hook registration primitives.
2. `lib/plugins/plugins.zsh` — declares plugins via `zdot_use` / `zdot_use_defer`, then
   manually re-lists deferred plugins inside `_plugins_load_deferred()`.

The manual re-listing in `_plugins_load_deferred()` duplicates what `zdot_use_defer`
declarations already know, creating an error-prone coupling. A previous rewrite of
`_plugins_load_deferred()` to call `zdot_load_plugin` directly also rendered
`zdot_load_deferred_plugins` dead code and introduced `_ZDOT_DEFER_SKIP_RECORD` as a
compensating hack. This design removes all of that.

---

## Goals

- Each plugin is declared once; the declaration carries enough information to generate the
  load hook automatically.
- No separate `_plugins_load_deferred()` function enumerating plugins a second time.
- No `plugins-declared` phase; `zdot_init` is the explicit line-in-the-sand.
- Dead code (`zdot_load_deferred_plugins`, `_ZDOT_DEFER_SKIP_RECORD`) is removed.
- Observability is preserved; the hook system already records what ran and when.

---

## New `zdot_use` API

### Existing form (unchanged)

```zsh
zdot_use <spec>              # clone only, no load hook
zdot_use <spec> fpath        # clone + add to fpath, no load hook
zdot_use <spec> path         # clone + add to PATH, no load hook
```

`<spec>` is either `user/repo` (GitHub shorthand) or an absolute path.

### New subcommand forms

```zsh
zdot_use <spec> hook [options]    # clone + register a synchronous load hook
zdot_use <spec> defer [options]   # clone + register a deferred load hook
```

Both forms:

1. Register the clone (same as bare `zdot_use`).
2. Generate a private loader function.
3. Register that function as a hook via `zdot_hook_register`.

The difference is that `defer` passes `--deferred` to `zdot_hook_register`, causing the
loader to be enqueued via `zdot_defer` (i.e. `zsh-defer`) instead of running synchronously.

### Shared options

| Option | Description |
|---|---|
| `--name <slug>` | Name of the generated hook and the value passed to `--name` in `zdot_hook_register`. If omitted, derived from `--provides` (or from `<spec>` as a last resort). Used with `zdot_defer_order`. |
| `--provides <phase>` | Phase token published after the plugin loads. Required if other hooks depend on this plugin being loaded. |
| `--config <fn>` | Zero-argument function called immediately before `zdot_load_plugin` inside the generated hook. Use for per-plugin configuration that must precede sourcing. |
| `--context <ctx>` | Space-separated context tokens (`interactive`, `noninteractive`). Forwarded to `zdot_hook_register`. Defaults to `interactive noninteractive`. |
| `--group <name>` | Tags this hook as a member of the named group. May be repeated to assign multiple groups. Forwarded to `zdot_hook_register`. |

### `defer`-only options

| Option | Description |
|---|---|
| `--requires <phase>` | Phase that must be published before this hook is enqueued. The scheduler will not enqueue the deferred hook until `<phase>` is available. |

`--requires` is **not valid** on `hook`. Non-deferred hooks fire at `zdot_init` time in
dependency order; the scheduler handles ordering through `--provides`/`--requires` on other
hooks. Passing `--requires` to `hook` is an error.

### What the forms generate

Given:

```zsh
zdot_use olets/zsh-abbr defer \
    --name zsh-abbr-load \
    --provides abbr-ready \
    --requires omz-plugins-loaded \
    --config _zdot_abbr_config
```

The implementation produces the equivalent of:

```zsh
function _zdot_autoload_zsh-abbr-load() {
    _zdot_abbr_config
    zdot_load_plugin olets/zsh-abbr
}

zdot_hook_register _zdot_autoload_zsh-abbr-load interactive noninteractive \
    --deferred \
    --name zsh-abbr-load \
    --provides abbr-ready \
    --requires omz-plugins-loaded
```

For `hook` (no `--deferred`, no `--requires`):

```zsh
zdot_use omz:plugins/git hook \
    --name omz-git \
    --provides omz-git-loaded
```

Produces:

```zsh
function _zdot_autoload_omz-git() {
    zdot_load_plugin omz:plugins/git
}

zdot_hook_register _zdot_autoload_omz-git interactive noninteractive \
    --name omz-git \
    --provides omz-git-loaded
```

---

## Hook Groups

Hook groups provide a way to express bulk dependency relationships without enumerating every
member hook individually. A group is purely a membership tag: belonging to a group does not
imply any implicit phase token or ordering between members of the same group.

### New options for `zdot_hook_register`

| Option | Description |
|---|---|
| `--group <name>` | Tags this hook as a member of the named group. A hook can belong to multiple groups. Has no ordering effect on its own. |
| `--requires-group <name>` | At DAG-build time, expands to `--requires <phase>` for every `--provides` token published by hooks tagged `--group <name>`. |
| `--provides-group <name>` | At DAG-build time, injects `--requires <this hook's provides>` into every hook currently tagged `--group <name>`. Requires `--provides` on the same registration. |

All group expansion happens inside `zdot_init` during DAG construction. Groups are resolved
after all hooks are registered (including those registered by bundle `--init-fn` functions
in the bundle init pass). Groups are never resolved eagerly.

### Group registry data structures

Two associative arrays track group membership. Both are populated at hook registration time
and serialized to the execution plan cache.

```zsh
# Forward map: hook_id → space-separated group names
# Used by zdot_show_hooks for display. Expanded with ${=var}.
typeset -gA _ZDOT_HOOK_GROUPS      # hook_id → "group1 group2 ..."

# Reverse index: group_name → space-separated hook_ids
# Used at DAG-build time to expand --requires-group / --provides-group.
typeset -gA _ZDOT_GROUP_MEMBERS    # group_name → "hook_id1 hook_id2 ..."
```

**Setting** (at registration time, when `--group <name>` is parsed):

```zsh
# Append group name to forward map
_ZDOT_HOOK_GROUPS[$hook_id]+=" $group_name"
_ZDOT_HOOK_GROUPS[$hook_id]="${_ZDOT_HOOK_GROUPS[$hook_id]# }"

# Append hook_id to reverse index
_ZDOT_GROUP_MEMBERS[$group_name]+=" $hook_id"
_ZDOT_GROUP_MEMBERS[$group_name]="${_ZDOT_GROUP_MEMBERS[$group_name]# }"
```

**Reading** (at DAG-build time, when `--requires-group <name>` is processed):

```zsh
for member_id in ${=_ZDOT_GROUP_MEMBERS[$group_name]}; do
    # inject --requires for each --provides token on $member_id
    for phase in ${=_ZDOT_HOOK_PROVIDES[$member_id]}; do
        # add edge: current hook requires $phase
    done
done
```

**Cache serialization** — `zdot_cache_save_plan` adds these lines inside the hook
metadata loop for `_ZDOT_HOOK_GROUPS`, and a separate loop for `_ZDOT_GROUP_MEMBERS`:

```zsh
# Inside per-hook_id loop (alongside _ZDOT_HOOK_CONTEXTS etc.):
echo "_ZDOT_HOOK_GROUPS[$hook_id]='${_ZDOT_HOOK_GROUPS[$hook_id]}'"

# Separate block after hook metadata, iterating over group names:
echo "typeset -gA _ZDOT_GROUP_MEMBERS"
for group_name in "${(@k)_ZDOT_GROUP_MEMBERS}"; do
    echo "_ZDOT_GROUP_MEMBERS[$group_name]='${_ZDOT_GROUP_MEMBERS[$group_name]}'"
done
```

The cache version constant in `core/cache.zsh` must be bumped from `"8"` to `"9"` when
this serialization is added.

### Semantics

**`--group <name>`** is a membership annotation. It can be combined with any other options.

**`--requires-group <name>`** reads the current membership of `<name>` and injects one
`--requires` edge per `--provides` token found on a member. This means the registering hook
will not fire until every hook in the group has published its phase.

**`--provides-group <name>`** is the inverse: it makes every current member of `<name>`
depend on this hook's `--provides` phase. Use it to insert a gate that the entire group
must wait for.

"Current membership" means membership at DAG-build time (inside `zdot_init`), not at
`zdot_hook_register` call time. Hooks registered after the DAG is built are not included.

### Example: compinit after all deferred plugins

```zsh
# Each deferred plugin joins the 'deferred-plugins' group and publishes its own phase.
zdot_use olets/zsh-abbr -defer \
    --name zsh-abbr-load \
    --provides abbr-ready \
    --group deferred-plugins

zdot_use zdharma-continuum/fast-syntax-highlighting -defer \
    --name fsh-load \
    --provides fsh-ready \
    --group deferred-plugins

# compinit fires only after every member of deferred-plugins has published.
zdot_hook_register _zdot_compinit interactive noninteractive \
    --deferred \
    --requires-group deferred-plugins \
    --provides compinit-done
```

At DAG-build time, `--requires-group deferred-plugins` expands to:
```
--requires abbr-ready --requires fsh-ready
```

No manual update is required when a plugin is added or removed; the group tag does the
bookkeeping.

### Example: gating an entire group on a single prerequisite

```zsh
# Mark every OMZ plugin load hook as part of 'omz-plugins'.
zdot_use omz:plugins/git    -hook --name omz-git    --provides omz-git-loaded    --group omz-plugins
zdot_use omz:plugins/docker -hook --name omz-docker --provides omz-docker-loaded --group omz-plugins

# OMZ lib must be loaded before any omz-plugins member fires.
zdot_hook_register _zdot_omz_load_lib interactive noninteractive \
    --provides omz-lib-loaded \
    --provides-group omz-plugins
```

At DAG-build time, `--provides-group omz-plugins` injects
`--requires omz-lib-loaded` into both `omz-git-loaded` and `omz-docker-loaded`.

### What groups do not do

- Groups do not impose ordering _between_ members. Members may fire in any order relative
  to each other (subject to their own `--requires`/`--provides` edges).
- Groups do not create implicit phase tokens. There is no `deferred-plugins-done` token
  unless a hook explicitly `--provides` it.
- Groups cannot be nested or composed; they are flat membership sets.

---

## `zdot_init`

`zdot_init` is a new function that replaces the `plugins-declared` phase as the explicit
synchronisation point between declarations and loading.

### Calling convention

```zsh
# lib/plugins/plugins.zsh

zdot_use omz:lib
zdot_use omz:plugins/git -hook --name omz-git --provides omz-git-loaded
# ... all declarations ...

zdot_init   # <-- the line in the sand
```

After `zdot_init` returns (or yields to the scheduler), all clone and load activity is
either complete or enqueued.

### What `zdot_init` does

1. **Clone all repos** — calls the equivalent of `zdot_plugins_clone_all`. Synchronous;
   all plugin source is on disk before any hooks fire.
2. **Bundle init pass** — for each entry in `$_ZDOT_BUNDLE_HANDLERS`, if
   `$_ZDOT_BUNDLE_INIT_FN[name]` is set, calls that function. Bundle init functions may
   call `zdot_hook_register` freely to register additional hooks (e.g. internal OMZ
   lifecycle hooks). They must not call `zdot_init` recursively.
3. **Build the DAG** — resolves all `--group`, `--requires-group`, and `--provides-group`
   annotations into concrete `--requires`/`--provides` edges. Includes hooks registered
   in step 2.
4. **Fire non-deferred hooks** — runs all hooks that were registered without `--deferred`,
   in DAG dependency order.
5. **Enqueue deferred hooks** — passes all `--deferred` hooks to `zdot_defer` in DAG
   dependency order, respecting `--requires` constraints.

### Calling convention

```zsh
# lib/plugins/plugins.zsh

zdot_use omz:lib
zdot_use omz:plugins/git -hook --name omz-git --provides omz-git-loaded
# ... all declarations ...

zdot_init   # <-- the line in the sand
```

After `zdot_init` returns (or yields to the scheduler), all clone and load activity is
either complete or enqueued.

### Replaces

- The `plugins-declared` phase token.
- The `--requires plugins-declared` on the clone hook and any hook that previously needed
  to wait for all declarations to be made.
- Any `zdot_execute_all` or equivalent function that previously kicked off loading.

---

## Plugin Bundle Interface

### Extended `zdot_bundle_register`

`zdot_bundle_register` gains two optional flags:

```zsh
zdot_bundle_register <name> [--init-fn <fn>] [--provides <phase>]
```

| Flag | Description |
|---|---|
| `--init-fn <fn>` | Zero-argument function called by `zdot_init` during the bundle init pass (step 2). May call `zdot_hook_register` freely to register additional internal lifecycle hooks. Must not call `zdot_init` recursively. |
| `--provides <phase>` | Phase token considered published once the bundle's `--init-fn` has returned. Used by `zdot_use` to auto-inject `--requires` on specs that belong to this bundle. |

The values are stored in two new associative arrays in `core/plugins.zsh`:

```zsh
typeset -gA _ZDOT_BUNDLE_INIT_FN    # bundle name → init function name
typeset -gA _ZDOT_BUNDLE_PROVIDES   # bundle name → phase token
```

### Updated four-function protocol

The four handler functions remain required and are identified by naming convention. The
`--init-fn` is a free-standing function name supplied at registration time — not a
naming-convention slot.

| Function | Required | Called by | Purpose |
|---|---|---|---|
| `zdot_bundle_<name>_match <spec>` | yes | `_zdot_bundle_handler_for` | returns 0 if this handler owns the spec |
| `zdot_bundle_<name>_path <spec>` | yes | `zdot_plugin_path` | sets `REPLY` to the filesystem path |
| `zdot_bundle_<name>_clone <spec>` | yes | `zdot_plugin_clone` | ensures the plugin is on disk |
| `zdot_bundle_<name>_load <spec>` | yes | `zdot_load_plugin` | sources or activates the plugin |

### Auto-requires in `zdot_use`

When `zdot_use <spec> -hook` or `zdot_use <spec> -defer` is called:

1. `_zdot_bundle_handler_for <spec>` identifies the handler name (e.g. `omz`).
2. If `$_ZDOT_BUNDLE_PROVIDES[<handler>]` is non-empty, `zdot_use` auto-injects
   `--requires <phase>` into the generated `zdot_hook_register` call.
3. An explicit `--requires` passed by the caller always wins; the auto-requires is
   silently skipped if the caller has already supplied one.

This means that:

```zsh
zdot_use omz:plugins/git -hook --name omz-git --provides omz-git-loaded
```

automatically becomes equivalent to:

```zsh
zdot_hook_register _zdot_autoload_omz-git interactive noninteractive \
    --name omz-git \
    --provides omz-git-loaded \
    --requires omz-bundle-initialized
```

without the caller having to know the bundle's phase token name.

### Example registration

```zsh
# core/plugin-bundles/omz.zsh
zdot_bundle_register omz \
    --init-fn  zdot_bundle_omz_init \
    --provides omz-bundle-initialized
```

```zsh
# core/plugin-bundles/pz.zsh
zdot_bundle_register pz \
    --init-fn  zdot_bundle_pz_init \
    --provides pz-bundle-initialized
```

---

## OMZ Bundle Init

### Overview

The ad-hoc `zdot_hook_register` calls currently at the bottom of `core/plugin-bundles/omz.zsh`
are replaced by a single init function, `zdot_bundle_omz_init`, called by `zdot_init`
during the bundle init pass.

### `zdot_bundle_omz_init` — execution order

```
zdot_bundle_omz_init:
  1. zdot_omz_check_for_upgrade
       Called here, before any OMZ machinery is initialised, matching
       the behaviour of oh-my-zsh.sh and use-omz.zsh. Previously defined
       in omz.zsh but never called anywhere; this is the call site.

  2. Set OMZ environment variables and state:
       ZSH_CUSTOM, ZSH_CACHE_DIR, theme state vars, async-prompt flags.
       (This work previously happened at file-source time or in _zdot_omz_load_lib;
       moving it here keeps file-source time side-effect-free.)

  3. zdot_hook_register _zdot_omz_load_lib interactive noninteractive \
         --provides omz-lib-loaded \
         --provides-group omz-plugins

  4. zdot_hook_register zdot_omz_theme_init interactive noninteractive \
         --requires omz-lib-loaded \
         --provides omz-theme-ready

  5. zdot_hook_register _zdot_omz_setup_prompt_funcs interactive noninteractive \
         --requires omz-lib-loaded \
         --provides omz-prompt-funcs-ready
```

Step 3 uses `--provides-group omz-plugins` so that any OMZ plugin load hook tagged
`--group omz-plugins` automatically gets `--requires omz-lib-loaded` injected at DAG-build
time without each plugin declaration having to spell it out.

### What is removed from `omz.zsh`

- The three bare `zdot_hook_register` calls at the bottom of the file (the ones that
  registered `_zdot_omz_load_lib`, `zdot_omz_theme_init`, and `_zdot_omz_setup_prompt_funcs`
  directly at file-source time).
- The `zdot_bundle_register omz` call is updated in-place to add `--init-fn` and
  `--provides`; the existing `zdot_use_bundle ohmyzsh/ohmyzsh` call below it is unchanged.

### `omz-init` group — dissolved

A previously discussed `omz-init` group is not needed: all option-setting now happens
directly inside `zdot_bundle_omz_init` (step 2) before the `zdot_hook_register` calls,
so no group is required to sequence it.

### PZ bundle init — same pattern

`core/plugin-bundles/pz.zsh` follows the identical pattern:

```
zdot_bundle_pz_init:
  1. Environment / state setup (ZSH_PREZTO_MODULES, etc.)
  2. zdot_hook_register _zdot_pz_load_init interactive noninteractive \
         --requires plugins-cloned \
         --provides pz-init-loaded
```

The existing bare `zdot_hook_register _zdot_pz_load_init` call in `pz.zsh` is replaced
by `zdot_bundle_pz_init` registered via `--init-fn`.

---

## What Is Removed

| Removed | Why |
|---|---|
| `zdot_load_deferred_plugins` (`core/plugins.zsh:514`) | Dead code; `_plugins_load_deferred()` already bypassed it |
| `zdot_load_all_plugins` (`core/plugins.zsh:504`) | Superseded by `zdot_init` |
| `_ZDOT_DEFER_SKIP_RECORD` global (`core/plugins.zsh:26`) | Was a compensating hack for `zdot_load_deferred_plugins` |
| `kind=defer` / `kind=normal` internal tracking | Replaced by hook registration |
| `plugins-declared` phase token | Replaced by `zdot_init` |
| `zdot_use_defer` (eventually) | Replaced by `zdot_use ... -defer`; kept as a deprecation alias initially |
| `_plugins_load_deferred()` (`lib/plugins/plugins.zsh:117–131`) | Replaced by per-plugin `-defer` declarations |
| `zdot_hook_register` block for `_plugins_load_deferred` (`lib/plugins/plugins.zsh:133–137`) | Replaced by per-plugin `-defer` declarations |
| `--provides plugins-declared` on `_plugins_configure` | Replaced by `zdot_init` |
| `--requires plugins-declared` on the core clone hook (`core/plugins.zsh:658`) | Replaced by `zdot_init` triggering clones directly |

---

## Migration: `lib/plugins/plugins.zsh`

### Before

```zsh
# zdot_use_defer calls scattered through the file
zdot_use_defer olets/zsh-abbr
zdot_use_defer zdharma-continuum/fast-syntax-highlighting
# ... etc ...

# _plugins_load_deferred — manual re-enumeration
function _plugins_load_deferred() {
    zdot_load_plugin olets/zsh-abbr
    zdot_load_plugin zdharma-continuum/fast-syntax-highlighting
    # ...
    zdot_defer -q zdot_compinit_defer
}
zdot_hook_register _plugins_load_deferred interactive noninteractive \
    --deferred \
    --requires omz-plugins-loaded \
    --provides plugins-loaded
```

### After

```zsh
zdot_use olets/zsh-abbr -defer \
    --name zsh-abbr-load \
    --provides abbr-ready \
    --requires omz-plugins-loaded

zdot_use zdharma-continuum/fast-syntax-highlighting -defer \
    --name fsh-load \
    --provides fsh-ready \
    --requires omz-plugins-loaded

# ... other deferred plugins ...

zdot_init
```

Each plugin carries its own hook declaration. The `_plugins_load_deferred()` function and
its `zdot_hook_register` block are deleted entirely. `zdot_compinit_defer` is handled
separately (either as its own `-defer` declaration or as a hook that `--requires` the last
deferred plugin's `--provides` phase).

### OMZ plugins

OMZ plugins that were loaded as a batch by `_plugins_load_omz` can stay as a batch or be
converted to individual `-hook` declarations depending on whether per-plugin phase
granularity is wanted. The batch approach is acceptable; convert only if ordering matters.

---

## Observability

No regression. The hook system already records:

- Hook function name
- `--name` slug
- `--provides` phase
- Whether deferred or not
- Invocation sequence

`zdot_show_defer_queue` and `zdot_show_hooks` (or equivalent) continue to surface this
information. The `_zdot_defer_record` parallel-array machinery remains in place for
deferred hooks; it is populated by the generated loader functions (which call `zdot_defer`)
exactly as before. `_ZDOT_DEFER_SKIP_RECORD` is removed because there is no longer any
inline recording path that conflicts with it.

---

## Files Affected

### `core/plugins.zsh`

| Change | Detail |
|---|---|
| `zdot_use` | Add `-hook` and `-defer` subcommand parsing; generate loader function and call `zdot_hook_register`; auto-inject `--requires <phase>` from `_ZDOT_BUNDLE_PROVIDES` when spec matches a bundle handler |
| `zdot_use_defer` | Rewrite as deprecation alias: `zdot_use "$1" -defer` |
| `zdot_load_all_plugins` | Remove |
| `zdot_load_deferred_plugins` | Remove |
| `_ZDOT_DEFER_SKIP_RECORD` | Remove global declaration and all references |
| Core clone hook (line 658) | Remove `--requires plugins-declared`; `zdot_init` triggers clones directly |
| `zdot_init` | Add new function (5-step: clone → bundle init pass → DAG build → fire hooks → enqueue deferred) |
| `_ZDOT_BUNDLE_INIT_FN` | Add new global associative array: bundle name → init function name |
| `_ZDOT_BUNDLE_PROVIDES` | Add new global associative array: bundle name → phase token published after bundle init |
| `zdot_bundle_register` | Extend to parse and store `--init-fn <fn>` and `--provides <phase>` into the new arrays |

### `core/plugin-bundles/omz.zsh`

| Change | Detail |
|---|---|
| `zdot_bundle_register omz` call | Add `--init-fn zdot_bundle_omz_init --provides omz-bundle-initialized` |
| Three ad-hoc `zdot_hook_register` calls | Remove; replaced by `zdot_bundle_omz_init` |
| `zdot_bundle_omz_init` | Add new function: calls `zdot_omz_check_for_upgrade`, sets state vars, registers the three OMZ hooks via `zdot_hook_register` |
| `zdot_omz_check_for_upgrade` | No change to definition; now called inside `zdot_bundle_omz_init` |

### `core/plugin-bundles/pz.zsh`

| Change | Detail |
|---|---|
| `zdot_bundle_register pz` call | Add `--init-fn zdot_bundle_pz_init --provides pz-bundle-initialized` |
| Ad-hoc `zdot_hook_register _zdot_pz_load_init` call | Remove; replaced by `zdot_bundle_pz_init` |
| `zdot_bundle_pz_init` | Add new function: sets Prezto state vars, registers `_zdot_pz_load_init` hook via `zdot_hook_register` |

### `lib/plugins/plugins.zsh`

| Change | Detail |
|---|---|
| `_plugins_configure` hook | Remove `--provides plugins-declared` |
| `zdot_use_defer` calls | Replace with `zdot_use ... -defer --name ... --provides ... --requires ...` |
| `_plugins_load_deferred()` | Remove entirely |
| `zdot_hook_register` for `_plugins_load_deferred` | Remove entirely |
| End of file | Add `zdot_init` call |

### `docs/PLUGIN_IMPLEMENTATION.md`

Review and update the "Phase Contract" section to reflect the removal of `plugins-declared`
and the introduction of `zdot_init`.

---

## Implementation Order

1. Add `_ZDOT_BUNDLE_INIT_FN` and `_ZDOT_BUNDLE_PROVIDES` associative arrays to `core/plugins.zsh`.
2. Extend `zdot_bundle_register` to parse and store `--init-fn` and `--provides` into the new arrays.
3. Add `-hook` / `-defer` parsing and hook generation to `zdot_use` in `core/plugins.zsh`, including auto-inject of `--requires` from `_ZDOT_BUNDLE_PROVIDES`.
4. Add `zdot_init` to `core/plugins.zsh` (5-step: clone → bundle init pass → DAG build → fire hooks → enqueue deferred).
5. Update the core clone hook to remove `--requires plugins-declared`.
6. Remove `zdot_load_all_plugins`, `zdot_load_deferred_plugins`, `_ZDOT_DEFER_SKIP_RECORD`.
7. Rewrite `zdot_use_defer` as a deprecation alias.
8. Migrate `core/plugin-bundles/omz.zsh`: update `zdot_bundle_register omz` call, write `zdot_bundle_omz_init` (including `zdot_omz_check_for_upgrade` call and three hook registrations), remove the three ad-hoc `zdot_hook_register` calls.
9. Migrate `core/plugin-bundles/pz.zsh`: update `zdot_bundle_register pz` call, write `zdot_bundle_pz_init`, remove the ad-hoc `zdot_hook_register _zdot_pz_load_init` call.
10. Rewrite `lib/plugins/plugins.zsh`: replace `zdot_use_defer` calls with `zdot_use ... -defer`, remove `_plugins_load_deferred()` and its hook registration, remove `--provides plugins-declared` from `_plugins_configure`, add `zdot_init` at end.
11. Update `docs/PLUGIN_IMPLEMENTATION.md`.
12. Smoke-test: new shell, `zdot_show_hooks`, verify load order matches expectations.
