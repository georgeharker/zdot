# Design: User-Defined Variant Contexts

> Validated against `core/` on 2026-06-10. Implemented as designed (originally 2026-03-17); pre-implementation text in git history.

The variant system adds a third, user-defined dimension to zdot's shell
context. The base context is the detected pair
`(interactive | noninteractive) × (login | nonlogin)`; the variant extends it
with an arbitrary user label — `work`, `small`, `server` — so a machine or
session can opt hooks in or out without editing module code.

Usage examples live in [Variants](../advanced.md#variants); flag tables live
in the [API reference](../api-reference.md). This document states the design
and the rationale.

## The Model

- The variant is a **single word** chosen by the user, not a fixed enumeration.
- **Exactly one variant is active** per shell session (possibly the empty
  string, meaning "default"). It is resolved once and never changes.
- Hooks carry optional include/exclude variant constraints. A hook with no
  constraint runs in every variant — pre-variant configurations behave
  identically.

**Why exactly one variant:** a single label keeps the cache keyspace, the
match predicate, and the mental model linear. Composite needs are expressed
as composite labels (`work-laptop`) rather than sets, which would force
power-set cache keys and ambiguous include/exclude semantics.

## Resolution — `core/ctx.zsh`

`zdot_resolve_variant` resolves the active variant once, with this priority:

1. `$ZDOT_VARIANT` environment variable — highest, so wrapper scripts and
   parent processes can override everything.
2. `zstyle ':zdot:variant' name <value>` — declarative `.zshrc` config.
3. A user-defined `zdot_detect_variant` function, which sets `REPLY`
   (hostname dispatch, file probes, etc.).
4. Otherwise the empty string: the default variant.

It is called from `zdot_build_context`, which composes
`_ZDOT_CURRENT_CONTEXT` and appends a `variant:<name>` token **only when the
variant is non-empty**. The prefix keeps variant tokens from colliding with
`interactive`/`login` tokens, and the conditional append keeps
`_ZDOT_CURRENT_CONTEXT` backward-compatible for consumers that only inspect
the base pair.

Runtime queries: `zdot_variant` prints the active variant (possibly empty);
`zdot_is_variant <name>` is the boolean guard for use inside hook bodies.

**Why resolve at plan-build time, not source time:** hooks are registered as
files are sourced, before the user's `.zshrc` has necessarily finished
expressing its variant choice. Resolving once inside `zdot_build_context`
(the first step of `zdot_build_execution_plan`) guarantees every registration
is visible before any variant-dependent decision is made.

## Global State — `core/core.zsh`

```zsh
typeset -g _ZDOT_VARIANT=""            # Active variant string (empty = default)
typeset -g _ZDOT_VARIANT_DETECTED=0    # 1 once zdot_resolve_variant has run
typeset -g _ZDOT_VARIANT_INDEX_BUILT=0 # 1 once _zdot_build_variant_provider_index has run
```

`_ZDOT_VARIANT_INDEX_BUILT` gates which provider registry lookups consult
(see below); it is set only on the plan-build path, never by a cache load.

## Hook Registration — `core/hooks.zsh`

`zdot_register_hook` parses `--variant <name>` and `--variant-exclude <name>`
in its raw-argument pre-pass. Both flags repeat; multiple `--variant` values
mean "any of". Constraints are stored per hook:

```zsh
typeset -gA _ZDOT_HOOK_VARIANTS          # hook_id -> "v1 v2 ..." (include; empty = all)
typeset -gA _ZDOT_HOOK_VARIANT_EXCLUDES  # hook_id -> "v1 v2 ..." (exclude)
```

`_zdot_variant_match <hook_id>` decides whether a hook runs in the active
variant:

1. If the active variant appears in the hook's exclude list, the hook is out.
2. An empty include list matches all variants.
3. A non-empty include list must contain the active variant.

**Why exclude beats include:** exclusion expresses "this must never load
here" (a heavy tool on a small machine), and a safety constraint must not be
defeated by a broader include added later or inherited from a barrier.
Checking the exclude first makes the conservative answer win.

## Plan Filtering and the Provider Index

`zdot_build_execution_plan` filters each hook through `_zdot_context_match`
and then `_zdot_variant_match` before it enters the dependency graph — a
variant-excluded hook simply does not exist in this shell's plan.

Phase providers are registered at source time under two-part keys in
`_ZDOT_PHASE_PROVIDERS_BY_CONTEXT` (`"<context>:<phase>"`). The variant is
unknown at that point, so the registry is never variant-keyed. Instead, after
the variant is resolved, `_zdot_build_variant_provider_index` builds a
filtered view:

```zsh
_ZDOT_PHASE_PROVIDERS_ACTIVE   # same keys, only hooks passing _zdot_variant_match
```

and sets `_ZDOT_VARIANT_INDEX_BUILT=1`. `_zdot_has_provider_in_contexts` uses
the active index when that flag is set and falls back to the full registry
otherwise — so introspection tools (`zdot_hooks_list` and friends) running
after a cache fast-path load still see every registered provider.

**Why the index is variant-filtered at plan time:** required-phase resolution
must not be satisfied by a provider the variant filter is about to remove.
Without the filtered view, a hook could pass dependency checks against a
provider that never runs, producing a plan that silently stalls; with it, a
missing provider is reported (or the requiring hook is skipped if
`--optional`) at plan-build, exactly as for context mismatches.

## Group Barrier Inheritance — `_zdot_init_resolve_groups`

Groups are implemented with synthetic begin/end barrier hooks. Barriers
derive their variant constraints from their members:

- **Include = union** of member include lists; if any member has an empty
  include list (matches all variants), the barrier's include list is also
  empty — one open member keeps the barrier open.
- **Exclude = intersection**: a variant is excluded by the barrier only if
  **every** member excludes it (computed by counting per-variant exclusions
  against the member count).

Both lists are written into `_ZDOT_HOOK_VARIANTS` /
`_ZDOT_HOOK_VARIANT_EXCLUDES` for the begin and end barrier hook ids, so
barriers flow through `_zdot_variant_match` like ordinary hooks.

**Why barriers inherit member variants:** a barrier should run iff at least
one member runs. Without inheritance, a group whose members are all filtered
out in the active variant would leave live barrier hooks with dangling phase
edges — ordering constraints against hooks that no longer exist in the plan.

## Plan Cache — `core/cache.zsh`

`_zdot_cache_context_suffix` produces a three-part key:

```
<interactive|noninteractive>_<login|nonlogin>_<variant>
```

with `default` substituted for the empty variant, giving plan files such as
`plans/execution_plan_interactive_nonlogin_work.zsh`. Introducing the third
part required a `_ZDOT_CACHE_VERSION` bump (the version has moved on since;
it is an opaque monotonic counter).

**Why the variant is part of the cache key:** the variant changes which hooks
are in the plan, so plans for different variants are different artifacts.
Keying the file by variant lets one machine keep warm caches for several
variants side by side instead of thrashing a single file.

The serialized plan also records `_ZDOT_HOOK_VARIANTS` and
`_ZDOT_HOOK_VARIANT_EXCLUDES` (non-empty entries only), plus
`_ZDOT_VARIANT` and `_ZDOT_VARIANT_DETECTED=1`, so a cache-loaded shell
answers `zdot_variant` / `zdot_is_variant` correctly. It deliberately does
**not** set `_ZDOT_VARIANT_INDEX_BUILT`: the filtering already happened when
the plan was built, and post-load tooling should consult the full provider
registry.

## Module Sugar Passthrough — `core/modules.zsh`

`zdot_define_module` accepts `--variant` / `--variant-exclude` at the module
level, collects them into a forwarded argument vector, and appends it to
**every** phase registration the module makes (configure, load, plugin
loaders, post-init, interactive-init, noninteractive-init). The constraint is
module-granular by design: a module either belongs on this variant or it does
not; per-phase variant splits would re-create the dangling-edge problem that
barrier inheritance exists to solve.

`zdot_simple_hook` needs no special handling — unrecognized flags pass
through verbatim to `zdot_register_hook`, which parses the variant flags
itself.

## Backward Compatibility

- Hooks and modules with no variant flags are untouched: empty include list
  matches every variant, including the default.
- `_ZDOT_CURRENT_CONTEXT` gains its `variant:` token only when a variant is
  active, so existing token consumers are unaffected.
- Old two-part plan-cache files are orphaned by the version bump and ignored.
