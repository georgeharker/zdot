# Dependency types — and when to use which

Every zdot hook declares how it relates to other hooks: what it needs, what it
provides, and what it should run after. zdot turns those declarations into a
dependency graph, topologically sorts it, and (for the deferred drain) re-checks
them at runtime. This page is the decision guide for **which kind of edge to
declare**.

The choice comes down to two questions:

1. **What should happen when the target isn't there?** Abort, skip me, or carry
   on?
2. **When the target *is* there, do I need to inherit its deferral?** i.e. if the
   thing I depend on runs in the deferred drain, must I too?

> The full flag reference (arguments, sugar forms) lives in
> [API → `zdot_register_hook`](api-reference.md#zdot_register_hook). This page is
> the *why/when*.

---

## The four edges at a glance

| Flag | When provider **present** | When provider **absent** |
|------|---------------------------|--------------------------|
| `--requires <phase>` | hard graph edge **+ force-defer propagation** | **abort the plan build** |
| `--requires-optional <phase>` | **identical to `--requires`** (hard edge + force-defer) | **drop dependency** — the hook still runs |
| `--optional` *(modifies `--requires`)* | hard edge + force-defer | **skip the whole hook** |
| `--after <target>` | **ordering only** — no force-defer propagation | silent no-op |

Two separate axes are in play, and it helps to read the table as such:

- **Absent behavior** (right column): `--requires` aborts, `--optional` skips the
  hook, `--after` and `--requires-optional` both let the hook run.
- **Present behavior** (left column): `--requires`, `--optional`, and
  `--requires-optional` are all *full* dependencies — they propagate
  **force-deferral** (if the provider runs in the deferred drain, so will you).
  `--after` is weaker: it orders you after the target but **does not** make you
  deferred.

That second axis is the subtle one. `--after X` looks like "a soft `--requires
X`," but it is not: it never inherits X's deferral. If you need "run after X, and
be deferred like X, *but* tolerate X being absent," `--after` silently drops the
deferral and your hook runs eagerly.

---

## Pick by intent

- **"X is a genuine prerequisite; without it I'm broken."** → `--requires X`.
  Let the build fail loudly — a missing hard requirement is a misconfiguration.

- **"I only make sense if X exists; otherwise don't run me at all."** →
  `--requires X --optional`. The hook is dropped (and, as a group member, dropped
  from its group's barrier rather than stalling it).

- **"I want to run after an *optional sibling* if it's loaded, with full
  dependency semantics — but I'm a base/common hook and must not depend on that
  sibling being present."** → `--requires-optional X`. This is the one to reach
  for when a hard `--requires` would wrongly couple a base module to an optional
  one. See the worked example below.

- **"Pure ordering — run after X if it happens to be around, no dependency, no
  deferral inheritance."** → `--after X` (or `--before X` for the mirror). Use it
  when you just want to slot in relative to another hook and genuinely don't care
  whether it ran.

---

## What `--requires-optional` actually does

`--requires-optional` is **`--requires` when the provider exists, and *nothing*
when it doesn't** — never `--after` (which is weaker even when the provider is
present).

The implementation does **not** strip the phase out when it's absent. The phase
always lives in the hook's requirement list, so the *present* case gets the exact
same machinery as `--requires` (real graph edge, force-defer propagation). What
makes the absent case soft is a side-set (`_ZDOT_DROPPED_OPTIONAL_PHASES`) that
**lets the entry pass** in both halves of the engine:

- **At plan-build (eager):** the absent phase is still iterated, but since nothing
  provides it the edge contributes **0** to the topological sort (no in-degree, no
  graph edge) instead of aborting the build.

- **At runtime (deferred drain):** the phase is still in the requirement list, but
  the runtime gate **passes over it** instead of waiting — so a deferred hook is
  never stalled forever on a phase that will never be provided.

Because the plan (and that side-set) is computed once at build and reused on every
shell via the plan cache, the dropped-set is serialized into the cache too — so a
cache-hit shell, which never re-runs the build, still knows to let the entry pass
in the drain.

The net effect is "no constraint," achieved by **preserve-and-pass**, not by
deletion. That distinction is what lets one requirement list serve both the
present case (full `--requires`) and the absent case (free pass), with the
present/absent decision made per-context at build time.

---

## Worked example: `completions` ↔ `autocompletion`

The `completions` module finalizes completions and launches `compinit`. It would
like to run *after* the optional `autocompletion` module's plugin stack (so those
plugins' completions are picked up), which is signalled by the phase
`autocomplete-post-configured`.

That phase is provided **only** by the `autocompletion` module. So the original:

```zsh
zdot_register_hook _completions_finalize interactive \
    --requires completions-paths-ready autocomplete-post-configured \
    ...
```

hard-coupled a **base** module to an **optional** one: a standalone config that
loaded `completions` without `autocompletion` (the README Quick Start) failed to
build a plan at all — *"no hook provides autocomplete-post-configured."*

`--after` is the wrong fix: `autocomplete-post-configured` is a *deferred* phase,
and `--after` would not propagate that deferral, so `_completions_finalize` would
run **eagerly** — before tools are on `PATH` and before `compinit`. The right
fix is `--requires-optional`:

```zsh
zdot_register_hook _completions_finalize interactive \
    --requires completions-paths-ready \
    --requires-optional autocomplete-post-configured \
    ...
```

- **`autocompletion` loaded:** full dependency — finalize is force-deferred behind
  it and ordered after its plugins, exactly as before.
- **`autocompletion` absent:** the edge is dropped, finalize runs without it, and
  the plan builds.

**Rule of thumb:** a base or commonly-loaded module must never *hard*-require a
phase that only an optional sibling provides. If it wants to order behind that
sibling when present, that's `--requires-optional`.

---

## Worked example: `--after` for ordering without dependency

Sometimes the *order* in which two hooks load matters even though neither needs
the other. The classic case is **ZLE widget wrappers**: `fzf-tab`, `zsh-abbr`,
and `zsh-autosuggestions` each rebind line-editor widgets (`self-insert`, the
completion menu, …). When more than one is active they must wrap in a consistent
order so each calls through to the next — but every one of them works perfectly
*on its own*. There is no dependency, only an ordering preference that applies
**if** the other is also loaded. That is exactly what `--after` expresses.

The `autocompletion` module wires the recommended chain (`fzf-tab → abbr →
autosuggest`) with soft edges:

```zsh
zdot_use_plugin olets/zsh-abbr defer \
    --name zsh-abbr-load --provides abbr-ready \
    --requires autocomplete-loaded \   # HARD: genuine dep — the module gate
    --after   fzf-tab-loaded           # SOFT: wrap after fzf-tab IF present

zdot_use_plugin zsh-users/zsh-autosuggestions defer \
    --name autosuggest-load --provides autosuggest-ready \
    --requires autocomplete-loaded \   # HARD: genuine dep
    --after   abbr-ready fzf-tab-loaded # SOFT: wrap after both, if present
```

Note the two flag kinds side by side: the *real* dependency (the module is
loaded) is `--requires`; the widget-wrap *ordering* (come after fzf-tab) is
`--after`. Because the ordering edges are soft:

- with all three present, they wrap in the right order and chain correctly;
- with `fzf-tab` disabled, `abbr`/`autosuggest` don't wait for it — the edge is a
  silent no-op and they still load.

`--requires` would be wrong here (disabling `fzf-tab` would abort the plan), and
so would `--requires-optional` — both frame the relationship as a *dependency*,
when really there is none: just "if you're both here, wrap in this order." Pure
ordering with no dependency and no deferral inheritance → `--after`.

---

## Related: groups

`--requires-group <name>` / `--provides-group <name>` express **fan-in / fan-out**
over a set of hooks rather than a single phase — "run after every member of this
group" (members that are skipped or filtered are dropped from the barrier, not
waited on). They're the right tool when an unknown set of producers should all
complete before a consumer. See
[API → `zdot_register_hook`](api-reference.md#zdot_register_hook) and
[Module Guide → groups](module-guide.md).
