# Design Documents

This folder holds three kinds of document, and only these:

- **Design records** — implemented designs kept because they remain the best
  explanation of an architecture and the reasoning behind it.
- **Decision records** — distillations of retired design work: what was
  proposed, what actually shipped, and *why the direction changed*. The
  retired originals (journals, transcripts, point-in-time reports) live in
  git history.
- **Open questions** — live, unresolved items, kept deliberately small.

The retention policy: a design doc stays only while it earns its place. Once
superseded, it is either deleted outright (if it taught nothing) or replaced
by a decision record capturing the learnings. Statuses below validated
against the implementation on 2026-06-10.

## Design records (implemented; authoritative rationale)

| Document | Covers |
|---|---|
| [plugin-hook-architecture.md](plugin-hook-architecture.md) | The hook + bundle plugin API: groups, bundle init, `zdot_init` orchestration. Shipped with renames (`zdot_use` → `zdot_use_plugin`, `zdot_hook_register` → `zdot_register_hook`). |
| [user-variant-context.md](user-variant-context.md) | The variant (third context dimension) system, implemented as designed. |
| [prezto-bundle.md](prezto-bundle.md) | Why Prezto became a second bundle handler and what compinit machinery had to move into core to allow it. |
| [compdump-and-clone-fastpath.md](compdump-and-clone-fastpath.md) | Investigation of compdump staleness and the clone fast-path sentinel; all four fixes shipped. Inline listings show the pre-fix code under analysis. |

## Decision records (what changed and why)

| Document | Distills |
|---|---|
| [update-architecture.md](update-architecture.md) | The self-update lineage (`update-rework{,2,3}`, `self-update`): why inline per-component self-update lost to hook-based Round 1/2 dispatch; rename map (`submodule-pointer` → `in-tree-commit`, `link-dest` → `destdir`); the repo-extraction subtree-split learning. |
| [compinit-caching-decisions.md](compinit-caching-decisions.md) | `omz-integration-analysis`, `cache-invalidation-refactor`, `fix-validation-report`: how the metadata pattern was adopted but generalized into core, why the precmd fix became moot (relay deleted; `finally` fallback), and the plan-cache force-refresh wiring. |
| [api-naming-and-sugar.md](api-naming-and-sugar.md) | The `api-improve` journal/plan/brainstorm: verb-first naming, no-shim renames, module sugar rollout, and the circular-dependency rules it taught. |

## Open questions

[open-questions.md](open-questions.md) — currently: batch plugin declaration
ergonomics, the `examples/` directory question, and the unresolved Ghostty
`ssh -G` hang.
