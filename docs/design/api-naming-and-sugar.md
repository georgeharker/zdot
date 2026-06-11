# Decision Record: API Naming & Module Sugar

**Distilled (2026-06-10)** from `api-improve.md` (implementation journal),
`api-improve-plan.md` (plan checklist), and `api-improvements.md`
(brainstorm) — all deleted; full text in git history. The surviving open
item moved to [open-questions.md](open-questions.md).

## What shipped

- **Verb-first naming** across the public API: `zdot_use` →
  `zdot_use_plugin`, `zdot_hook_register` → `zdot_register_hook`,
  `zdot_bundle_register` → `zdot_register_bundle`, and the rest of the
  rename chunks. **No compatibility shims** — old names were removed
  outright (pre-1.0, single-digit consumers).
- **Module sugar**: `zdot_simple_hook` (single-hook modules) and
  `zdot_define_module` (multi-phase plugin lifecycles). The original
  rollout converted ~20 modules (the plan recorded 14 simple_hook + 6
  define_module call sites); today 20 built-in module files carry 22 call
  sites (12 `zdot_simple_hook` + 10 `zdot_define_module` — a file can hold
  several, e.g. fzf) as new modules adopted the sugar and some converted
  between forms. Modules with genuinely bespoke hook graphs (xdg, secrets,
  completions, venv, plugins) intentionally stay on manual
  `zdot_register_hook`.
- `--auto-bundle` was renamed **`--auto-bundle-deps`** late: the flag wires
  the bundle's dependency *edges* (group + requires) onto the generated
  load hook; it does not create a bundle, and the old name suggested it
  did.
- The naming rationale: verbs read as imperatives at call sites, and the
  declare/act split stays visible — `zdot_use_plugin` *declares* (parse
  time), `zdot_load_plugin` *acts* (hook time).

Current truth: [api-reference.md](../api-reference.md) and the
[Module Writer's Guide](../module-guide.md).

## Learning: the circular-dependency rollout bug

Converting modules to the sugar surfaced a circular dependency that
informed two standing rules:

1. **Providers and consumers must agree on context.** A phase provided
   only by an `interactive`-context hook is unsatisfiable in the
   noninteractive plan; the consumer then appears circular/unplanned. The
   fix (fzf) was aligning the provider's context list with its consumers.
2. **Bundle handlers declare a provides phase.** The OMZ handler initially
   published no phase, so framework plugins could not order against
   framework init. `zdot_register_bundle --provides <phase>` plus
   `--auto-bundle-deps` consuming it is the durable fix.

## Deferred cleanup (from the plan's chunk 5)

The stale-file removal the plan deferred (`plugins.zsh.bak`) has since
happened — no `.zsh.bak` files remain in the tree. Module header-comment
passes remain opportunistic.
