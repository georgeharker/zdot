# Decision Record: Self-Update Architecture

**Distilled (2026-06-10)** from `update-rework.md`, `update-rework2.md`,
`update-rework3.md`, and `self-update.md` (all deleted; full text in git
history). Records what those designs proposed, what actually shipped, and why
the direction changed.

## What shipped

Self-update is a **hook-based, two-round dispatch** shared between dotfiler
and its components (zdot, dotfiler-self):

- **Shared primitives** live in dotfiler's `update_core.zsh`: deployment
  topology detection (`_update_core_detect_deployment` —
  standalone/submodule/subtree/subdir), lock + timestamp gating
  (`_update_core_acquire_lock`, `_update_core_should_update`), availability
  checks (`_update_core_is_available`, API-first with git fallback), and
  parent pointer/marker commits (`_update_core_component_post_marker`).
- **Components register phase hooks** (check / plan / pull / unpack / post)
  with dotfiler's registry. zdot's side is `core/update.zsh` (startup
  bootstrap) + `core/update-impl.zsh` (the `_zdot_update_hook_*` family),
  discovered via the linktree hook symlink.
- **Round 1 (dotfiles-directed)** applies the pointer/marker the dotfiles
  repo records; **Round 2 (self-directed)** advances each component from its
  own upstream, gated by `release-channel`.

Two properties of the shipped shape worth naming explicitly:

- **Zero overhead for non-participants**: update mode defaults to
  `disabled`, and a disabled zdot registers nothing — non-opted-in shells
  pay no startup or network cost, and dotfiler (when present) owns the
  whole update cycle alone.
- **Components reuse dotfiler's link-tree machinery** rather than carrying
  their own: the setup primitives gained `--repo-dir`/`--link-dest`
  parameters precisely so a component (zdot) can unpack its symlinks to an
  arbitrary destination (`$XDG_CONFIG_HOME/zdot`) instead of `$HOME`.

User-facing docs: dotfiler's `how-updates-work.md` and `update-hooks.md`;
zdot's `zstyle-reference.md` (`:zdot:update`).

## What the designs proposed, and why it changed

The design lineage proposed **inline per-component self-update**: a
`handle_self_update()` beside `handle_update()` in `check_update.zsh`
(update-rework2), then a zdot-side function inventory
(`_zdot_update_detect_deployment`, `_zdot_update_is_available`,
`_zdot_update_apply`, lock/timestamp helpers — update-rework3, self-update).
That shape lost to the hook registry for three reasons:

1. **Duplication scales with components.** Inline functions repeat
   lock/timestamp/topology/apply logic per component; the registry gives N
   components one engine, each contributing only its phase hooks.
2. **Partial-update safety needs indirection.** The hook file is sourced
   from its *linktree* path, which only advances during a successful unpack —
   so dotfiler always executes the last cleanly-installed hook code, never a
   half-pulled version. Inline code in `check_update.zsh` cannot get this
   property.
3. **Ordering guarantees.** Dotfiles-first (Round 1 before Round 2) ensures
   new hook code is delivered and symlinked before it is ever executed.
   The phase split (plan → pull → unpack → post) made that ordering explicit
   instead of implicit in one function body.

`update-rework.md`'s one-liner (consolidate `update_core.zsh` unsets into a
cleanup function) was absorbed into the registry's init/cleanup callbacks.

## Rename map (design name → shipped name)

| Design | Shipped | Notes |
|---|---|---|
| `submodule-pointer` (zstyle) | `in-tree-commit` | Same `none\|prompt\|auto` semantics — what to do with the parent repo's pointer/marker after a component update. Default is `auto`. |
| `link-dest` (zstyle) | `destdir` | Link-tree unpack destination. |
| `handle_self_update()` | `_update_dotfiler_*` phase hooks | dotfiler-self updates via the same registry as components. |
| `_zdot_update_detect_deployment` etc. | `_update_core_detect_deployment` + `_zdot_update_hook_*` | Shared primitive + per-component hooks. |
| Phase 1 / Phase 2 (zdot docs) | Round 1 / Round 2 | Terminology unified with dotfiler's docs. |

## Repo extraction note

(From the deleted `extract-zdot.md` transcript.) When zdot was extracted into
its own repository, `git subtree split --prefix=<dir>` failed with
`fatal: no new revisions were found` because the tree had been *renamed*
(`.config/zsh/zdot` → `.config/zdot`) and subtree split does not follow
renames. `git filter-repo` handles renamed paths and was the workable
extraction route.
