# Plugin Hook Architecture

> Validated against `core/` on 2026-06-10. History: this design shipped (renames: `zdot_use` → `zdot_use_plugin`, `zdot_hook_register` → `zdot_register_hook`); the original pre-implementation text is in git history.

This document describes the architecture of zdot's plugin and hook system and the
rationale behind its shape. Internals (data structures, cache serialization, file
walkthroughs) are owned by [../plugin-implementation.md](../plugin-implementation.md);
consumer how-to is owned by [../using-plugins.md](../using-plugins.md). The full
flag reference for hooks lives in [../api-reference.md](../api-reference.md) and
[../module-guide.md](../module-guide.md).

## The declare / clone / load model

Plugin handling is split into three stages with a hard line between them:

1. **Declare** — `zdot_use_plugin` calls record what is wanted: the spec, an
   optional version pin (`user/repo@ref`), and a generated load hook. Nothing
   touches disk or sources code.
2. **Clone** — `zdot_init` runs `zdot_plugins_clone_all` (`core/plugins.zsh`)
   once, synchronously, so every declared repo is on disk before any load hook
   fires. A sentinel file (`.cloned` in the plugins cache) makes the
   nothing-changed case a string comparison instead of N git invocations.
3. **Load** — `zdot_load_plugin` sources a plugin on demand, exactly once
   (deduplicated via `_ZDOT_PLUGINS_LOADED`), either eagerly during the hook
   plan or post-prompt via the deferred drain.

**Why declaration is split from loading:** each plugin is declared once, and the
declaration carries everything needed to generate its load hook. Loading is then
driven entirely by the hook scheduler's dependency graph — there is no second,
hand-maintained list of "what to load and when" that can drift out of sync with
the declarations. Ordering, deferral, and observability all come for free from
the hook system instead of being re-implemented per plugin.

## `zdot_use_plugin`

Defined in `core/plugins.zsh`. Declaration forms:

```zsh
# Hook-generating forms (preferred)
zdot_use_plugin <spec> hook  [--name <n>] [--provides <p>] [--config <fn>] [--context <c>...]
                             [--group <g>]... [--requires-group <g>] [--provides-group <g>]
zdot_use_plugin <spec> defer [...same...] [--requires <phase>]
zdot_use_plugin <spec> defer-prompt [...same as defer...]

# Legacy forms (record the spec for cloning only; no hook)
zdot_use_plugin <spec>                       # kind=normal
zdot_use_plugin <spec> normal|fpath|path
```

`<spec>` is `user/repo` (GitHub shorthand, optionally `@ref`-pinned), an absolute
path, or a bundle spec such as `omz:plugins/git` / `pz:modules/git`.

The hook-generating forms do three things:

1. Record the spec for the clone phase (`_ZDOT_PLUGINS_ORDER` / `_ZDOT_PLUGINS`).
2. Generate a private loader function `_zdot_autoload_<name-or-spec>` that runs
   the optional `--config` function and then `zdot_load_plugin <spec>`. The
   `--config <fn>` callback is invoked as `<fn> <plugin-path> <spec>` *before*
   the plugin is sourced — its purpose is configuration that must precede
   sourcing.
3. Register the loader via `zdot_register_hook`, forwarding `--provides`,
   `--group`, `--requires-group`, `--provides-group`, and the contexts
   (default: `interactive noninteractive`).

The subcommand selects the scheduling mode:

- `hook` — synchronous: the loader runs in the eager pass of the execution plan.
  `--requires` is rejected here; eager ordering is expressed by other hooks
  requiring this plugin's `--provides` phase.
- `defer` — adds `--deferred`: the loader runs post-prompt via the deferred
  drain. `--requires <phase>` gates when it becomes eligible.
- `defer-prompt` — deferred variant that keeps prompt redraw enabled, for
  plugins that change the prompt (emits `--deferred-prompt`).

**Bundle auto-requires:** for `defer`/`defer-prompt`, if a registered bundle
handler owns the spec and the bundle declared `--provides <phase>` at
registration, that phase is auto-injected as the hook's `--requires` (an
explicit `--requires` from the caller wins). Why: a consumer declaring
`zdot_use_plugin omz:plugins/git defer` should not need to know the bundle's
internal initialization phase token.

## The hook registration model

`zdot_register_hook` (`core/hooks.zsh`) is the single primitive everything else
compiles down to:

```zsh
zdot_register_hook <fn> <context...> \
    [--requires <phase>...] [--provides <phase>]... [--optional] \
    [--after <target>...] [--before <target>...] \
    [--name <label>] [--deferred | --deferred-prompt] \
    [--group <g>]... [--requires-group <g>] [--provides-group <g>] \
    [--variant <v>]... [--variant-exclude <v>]...
```

It sets `REPLY` to the new hook id. The essentials for understanding plugins:

- **Contexts** are shell-kind filters: `interactive`, `noninteractive`, `login`,
  `nonlogin`. A hook absent from the current context simply never enters the
  plan.
- **Phases** are string tokens. `--provides` publishes one when the hook
  succeeds; `--requires` is a hard dependency edge (missing provider is an
  error unless the hook is `--optional`). Phase providers are unique per
  context — two hooks providing the same phase in the same context is a
  registration error, which keeps the graph unambiguous. `tool:` phases (via
  the `--provides-tool`/`--requires-tool` sugar) are the first-registered-wins
  exception.
- **Soft ordering** — `--after`/`--before` order against a phase or hook name
  if it exists, and are silent no-ops if it does not. `zdot_defer_order`
  expresses the same thing externally, between named hooks.
- **Deferral** — `--deferred` hooks are excluded from the eager pass and
  dispatched post-prompt. A non-deferred hook that requires a phase provided
  only by a deferred hook is *force-deferred*, transitively, with a warning
  (silenceable via `zdot_allow_defer`). Why: a dependency on late work must
  move the dependent later; silently running it early with the phase missing
  would be worse than warning.

`zdot_build_execution_plan` runs Kahn's algorithm over the registered hooks
(filtered by context and variant) and produces `_ZDOT_EXECUTION_PLAN` plus its
deferred subset. `zdot_execute_all` runs the eager portion in plan order, then
seeds the deferred drain: `_zdot_run_deferred_phase_check` dispatches every
deferred hook whose required phases are present, and each completed hook re-runs
the check — a chain reaction that executes the deferred DAG in dependency order
with no polling loop, plus stall detection when a required phase can never
arrive.

## Groups and barrier synthesis

A group is a flat membership tag used to express bulk dependencies without
enumerating members:

- `--group <g>` — joins group `<g>` (repeatable; membership only, no ordering
  between members).
- `--requires-group <g>` — this hook runs after *every* member of `<g>` (edge
  from the group's end barrier).
- `--provides-group <g>` — this hook runs before *every* member of `<g>`: the
  group's begin barrier waits on it (the mirror image of `--requires-group`).
  The provider is not itself a member.

Groups resolve late, in `_zdot_init_resolve_groups` (`core/hooks.zsh`), called
by `zdot_init` *after* the bundle init pass — so membership is complete,
including hooks registered by bundle init functions, before any edges are
derived. Resolution synthesises two no-op **barrier hooks** per group `G`:
`_zdot_group_begin_G` (provides `_group_begin_G`) and `_zdot_group_end_G`
(provides `_group_end_G`). Each member requires the begin phase and provides a
per-member phase `_group_member_G_<hook_id>` that the end barrier requires,
context-restricted to that member's contexts; `--requires-group G` becomes a
plain `--requires _group_end_G`.

**Why barriers instead of edge expansion:** the group becomes two ordinary nodes
in the same DAG, so every existing mechanism — topological sort, force-deferral,
context filtering, plan caching, introspection — handles groups with no special
cases. Adding or removing a member changes nothing outside the barrier wiring.

Two group names are reserved and get extra ordering in the planner: `pre-defer`
(members run as the last eager step, just before the first prompt) and
`finally` (members run after the deferred drain has quiesced). Bundles lean on
ordinary groups for their configuration windows: omz uses `omz-configure` and
`omz-plugins`, pz uses `pz-configure`, so user `zstyle`/configuration hooks can
join a group and be guaranteed to run before the bundle consumes the settings.

## The bundle handler registry

Bundles exist because some "plugins" are *sub-specs of one shared repository*
with their own path layout, load semantics, and initialization lifecycle —
oh-my-zsh (`omz:lib`, `omz:plugins/<name>`) and Prezto (`pz:modules/<name>`)
being the two shipped handlers (`core/plugin-bundles/omz.zsh`, `pz.zsh`).
Without bundles, every OMZ-ism would leak into `core/plugins.zsh`.

`zdot_register_bundle <name> [--init-fn <fn>] [--provides <phase>]` registers a
handler. A handler owns specs via a naming-convention contract:

| Function | Required | Purpose |
|---|---|---|
| `zdot_bundle_<name>_match <spec>` | yes | returns 0 if this handler owns the spec |
| `zdot_bundle_<name>_path <spec>`  | yes | sets `REPLY` to the on-disk path |
| `zdot_bundle_<name>_clone <spec>` | yes | ensures the plugin is on disk |
| `zdot_bundle_<name>_load <spec>`  | yes | sources/activates the plugin |
| `zdot_bundle_<name>_repo/_url/_name` | no | git dir / clone URL / display label for update tooling |

`zdot_plugin_path`, `zdot_plugin_clone`, `zdot_load_plugin`, etc. each probe
`_zdot_bundle_handler_for` and delegate when a handler matches; plain
`user/repo` specs fall through to the GitHub defaults. The shared backing repo
is registered with `zdot_use_bundle <repo>` so cleanup tooling does not treat it
as an orphan.

The two registration flags carry the lifecycle:

- `--init-fn <fn>` — called by `zdot_init` during the bundle init pass. Its job
  is to register the bundle's internal hooks (it must not call `zdot_init`).
  Deferring these registrations into an init function — rather than doing them
  at file-source time — means they happen after all user declarations and
  before group resolution, so group-based configuration windows
  (`omz-configure`) see complete membership. omz registers three hooks here:
  setup (`--requires-group omz-configure --provides omz-bundle-initialized`),
  lib load (`--requires omz-bundle-initialized --provides omz-lib-loaded
  --provides-group omz-plugins`), and theme init (`--requires omz-lib-loaded
  --provides omz-theme-ready`). pz registers one
  (`_zdot_pz_load_init --requires plugins-cloned --requires-group pz-configure
  --provides pz-bundle-initialized pz-init-loaded`).
- `--provides <phase>` — the phase consumers of this bundle's specs implicitly
  depend on; it feeds the auto-requires injection in `zdot_use_plugin`
  described above. omz registers `--provides omz-bundle-initialized`; pz
  currently registers no `--provides`.

## `zdot_init` — orchestration

`zdot_init` (`core/init.zsh`) is idempotent (`_ZDOT_INIT_DONE`) and runs, in
order:

1. **Clone** — executes the pre-registered `plugins-cloned-init` hook
   (`--provides plugins-cloned`), which calls `zdot_plugins_clone_all`. All
   source is on disk before anything fires.
2. **Bundle init pass** — `_zdot_init_bundles` calls each registered bundle's
   `--init-fn`.
3. **Group resolution** — `_zdot_init_resolve_groups` synthesises barriers and
   concrete edges. Runs every shell, even on plan-cache hits, because the
   barrier hook ids it captures are deliberately not serialized.
4. **Plan and execute** — `load_cache` restores the cached execution plan, or
   `zdot_build_execution_plan` + `zdot_cache_save_plan` build and cache it
   (`core/cache.zsh`, versioned via `_ZDOT_CACHE_VERSION`); then
   `zdot_execute_all` runs the eager plan and enqueues the deferred drain.
5. **Compile** — `zdot_cache_compile_all` byte-compiles after execution, since
   hooks may generate new `.zsh` files.

**Why a single trigger:** `zdot_init` is the explicit line in the sand between
declaration and execution — the user's `.zshrc` makes all `zdot_use_plugin` /
`zdot_register_hook` declarations and then calls `zdot_init` exactly once at
the end. There is no "declarations finished" phase token to remember to provide,
no implicit kick-off a module could race; everything before the call is pure
registration, and everything after is driven by one dependency graph built from
a complete picture. This replaced the earlier `plugins-declared` phase and the
hand-enumerated deferred-load functions that duplicated the declarations.

## Alternatives considered

- **Per-plugin load lists** (the pre-redesign state): deferred plugins were
  re-enumerated in a manual loader function. Rejected because every addition had
  to be made twice and the two lists drifted.
- **A `plugins-declared` phase instead of `zdot_init`:** rejected because a
  phase has to be provided by *some* hook, which reintroduces the question of
  who runs last; an explicit function call is unambiguous.
- **Eager group resolution at registration time:** rejected because membership
  is incomplete until the bundle init pass; late resolution inside `zdot_init`
  sees the whole graph.
