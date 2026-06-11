# Design: Prezto Plugin Bundle

> Validated against `core/` on 2026-06-10. The original viability study is in git history.

The Prezto bundle (`core/plugin-bundles/pz.zsh`) lets users load
[Prezto](https://github.com/sorin-ionescu/prezto) modules through the standard
plugin interface — `zdot_use_plugin pz:modules/git`, or the sugar wrapper
`zdot_use_pz git` — alongside, or instead of, the OMZ bundle. Consumer-facing
usage is documented in [Using plugins](../using-plugins.md); this document
records the shape of the implementation and why it is shaped that way.

## Enablement

The bundle is gated by `zstyle ':zdot:plugins' pz` and is **off by default**
(read with `zstyle -b`, so an absent style means disabled). This is the
opposite default from OMZ, which is gated by `zstyle -T ':zdot:plugins' omz`
and defaults to **on**.

**Why default-off:** OMZ is zdot's primary framework and several shipped
modules depend on `omz:` specs. Prezto is an additive second framework:
enabling it clones the full Prezto repository with submodules, which no user
should pay for unless they asked for it. When disabled, the bundle file
defines its handler functions but registers nothing — no clone, no hooks, no
registry entry.

## Handler shape

The bundle implements the standard handler contract (see
[Writing a bundle handler](../advanced.md#writing-a-bundle-handler) for the
contract itself, and [Plugin implementation](../plugin-implementation.md) for
registry internals):

| Function | Behaviour |
|----------|-----------|
| `zdot_bundle_pz_match` | Owns any `pz:*` spec |
| `zdot_bundle_pz_repo` | `REPLY` ← the single `sorin-ionescu/prezto` checkout, via `zdot_plugin_path` |
| `zdot_bundle_pz_url` | `REPLY` ← the upstream URL, via `zdot_plugin_url` |
| `zdot_bundle_pz_path` | `pz:modules/git` → `<repo>/modules/git` |
| `zdot_bundle_pz_clone` | No-op (repo cloned at file-source time); populates `_ZDOT_PLUGINS_PATH[$spec]` for the clone fast-path sentinel |
| `zdot_bundle_pz_load` | `pz:modules/<name>` → `pmodload <name>` |

Registration happens only when enabled:
`zdot_register_bundle pz --init-fn zdot_bundle_pz_init`, followed by
`zdot_use_bundle sorin-ionescu/prezto`. The `_repo`/`_url` resolvers delegate
to the public plugin resolvers so the cache path and GitHub URL conventions
stay defined in one place (`core/plugins.zsh`).

**Why loading delegates to `pmodload` instead of mapping pz specs onto
OMZ-style loading:** a Prezto module is not a `.plugin.zsh` file. It is a
directory with an `init.zsh` entry point, an optional `functions/` directory
whose contents must be autoloaded *before* `init.zsh` is sourced, and
idempotence tracked in Prezto's own `zstyle ':prezto:module:<name>' loaded`
state. Reimplementing that in zdot would fork Prezto's loader and silently
drift from it. Delegating to `pmodload` — a public, idempotent, stable API —
keeps Prezto semantics exactly. This is the case the bundle-handler contract
exists for: each framework keeps its native loader behind a uniform spec
interface.

`zdot_bundle_pz_load` only acts on `pz:modules/*` specs; Prezto `contrib/`
modules are not supported.

## Bootstrap sequence

Cloning happens at file-source time, not per-spec. When the bundle is
enabled, `pz.zsh` immediately:

1. calls `_zdot_plugins_init` so the cache dir exists before resolvers touch it;
2. sets `ZPREZTODIR` to the checkout path (`zdot_plugin_path sorin-ionescu/prezto`);
3. clones via `zdot_plugin_clone sorin-ionescu/prezto` — the shared clone path
   in `core/plugins.zsh` uses `git clone --recurse-submodules`, which Prezto
   needs for its `external/` submodules.

**Why at source time:** every `pz:*` spec is backed by the same single
checkout, and `ZPREZTODIR` must point at it before anything else references
it. A per-spec clone step would just re-discover the same repo; instead the
per-spec `zdot_bundle_pz_clone` is a no-op that records the path.

Prezto's own `init.zsh` is sourced later, from a hook.
`zdot_bundle_pz_init` registers `_zdot_pz_load_init` with:

```zsh
zdot_register_hook _zdot_pz_load_init interactive noninteractive \
    --requires plugins-cloned \
    --provides pz-bundle-initialized \
    --provides pz-init-loaded \
    --requires-group pz-configure
```

So Prezto bootstraps after the `plugins-cloned` phase (the repo is guaranteed
on disk) and after any user hooks in the `pz-configure` group (Prezto reads
its `zstyle` configuration when `init.zsh` is sourced, so user zstyles must
land first — the same pattern the OMZ bundle uses with its `omz-configure`
group). Downstream hooks that need `pmodload` available depend on
`pz-init-loaded`.

## The `.zpreztorc` stub

Prezto's `init.zsh` unconditionally sources `${ZDOTDIR:-$HOME}/.zpreztorc`.
If no such file exists, `_zdot_pz_load_init` writes a minimal stub whose only
directive is an empty module list:

```zsh
zstyle ':prezto:load' pmodules
```

**Why Prezto must not auto-load modules:** Prezto's native behaviour is to
load everything listed in `':prezto:load' pmodules` the moment `init.zsh` is
sourced — outside zdot's hook graph entirely. Modules loaded that way are
invisible to the plan: no dependency edges, no deferral, no milestones, and a
double-load risk for anything also declared via `pz:` specs. zdot owns the
load plan, so Prezto is deliberately reduced to a loader library: `init.zsh`
provides `pmodload`, and zdot decides what gets loaded and when.

**Why a stub rather than nothing:** an empty `pmodules` list pins that
contract in the file Prezto actually reads. Without the stub, a user
following Prezto's own documentation would create a `.zpreztorc` that
auto-loads modules and reintroduce exactly the bypass described above. An
existing user `.zpreztorc` is never overwritten — Prezto-internal styles
(editor keymap, colours, per-module settings) belong there and still work.

## Coexistence with OMZ

Both bundles register into the same registry; `omz:` and `pz:` prefixes are
disjoint, so handler dispatch never collides. Sourcing order in `zdot.zsh` is
`core/compinit.zsh`, then `plugin-bundles/omz.zsh`, then
`plugin-bundles/pz.zsh`.

The frameworks themselves still share global surfaces, so two constraints
apply:

- **Prompt:** Prezto's `prompt` module and the OMZ theme machinery
  (`ZSH_THEME` / `zdot_omz_theme_hook`) both set `PROMPT`. Load at most one.
- **Completion:** zdot owns `compinit` (below). Loading
  `pz:modules/completion` would run Prezto's own `compinit` against Prezto's
  own dump file on top of zdot's; use zdot's completions module instead.

Utility modules from both frameworks mix freely.

## Shared compinit in core

The compinit machinery lives in `core/compinit.zsh`, sourced before either
bundle: the `compdef` stub and `_ZDOT_COMPDEF_QUEUE` (plugins call `compdef`
at source time, before compinit has run), the idempotent `zdot_compinit_run`
entry point, the pluggable `_zdot_compdump_path` and
`_zdot_compdump_needs_refresh` helpers, and the compdump metadata/recompile
support. The primary launch is the completions module's
`_completions_compinit` hook (`--deferred --requires-group completions`),
with a core `finally`-group fallback (`_zdot_compinit_fallback`) so compinit
runs even in configurations without that module.

**Why compinit had to move to core for two bundles to coexist:** when the
machinery lived in `omz.zsh`, a second bundle needing completions had two bad
options — call OMZ-internal functions (a hard cross-bundle dependency that
breaks the moment the OMZ bundle is disabled) or run its own `compinit`
against its own dump file (two compinit passes, divergent completion state).
A single core-owned, idempotent runner gives every bundle the same answer:
contribute to `fpath`, queue `compdef` calls, and let core run compinit once
after all producers have drained.

### What remains asymmetric

The extraction is deliberately partial. OMZ-specific staleness logic still
lives in `omz.zsh`: when OMZ is enabled it overrides
`_zdot_compdump_bundle_stamp` (a core stub that defaults to empty) to return
the OMZ checkout's `git rev-parse HEAD`, feeding the compdump refresh check.
That override is a single global function slot, not a per-bundle mechanism —
with both bundles enabled, the stamp tracks only OMZ's revision. Prezto
revision changes are still caught, but by the generic plugin-revision path
(`zdot_plugins_have_changed` → `_ZDOT_FORCE_COMPDUMP_REFRESH`) rather than by
a pz-specific stamp. The rationale for this overall compinit/caching shape —
including why the force-refresh flag was chosen over per-bundle metadata — is
recorded in
[compinit-caching-decisions.md](../design/compinit-caching-decisions.md);
this document does not restate it.

## Pointers

- [Using plugins](../using-plugins.md) — enabling the bundle and declaring `pz:` specs
- [Writing a bundle handler](../advanced.md#writing-a-bundle-handler) — the handler contract the pz bundle implements
- [Plugin implementation](../plugin-implementation.md) — registry internals and the compinit flow
