# Design: Prezto Plugin Bundle

**Status:** Draft  
**Date:** 2026-02-19  
**Scope:** Research and architecture — no code changes proposed here

---

## 1. Background and Motivation

zdot currently supports one plugin-bundle type: `omz` (Oh My Zsh). A plugin-bundle is the unit of integration between zdot and a third-party plugin framework. Adding a `prezto` bundle would let users load [Prezto](https://github.com/sorin-ionescu/prezto) modules through the standard `zdot_use` interface instead of wiring Prezto manually.

This document answers two driving questions:

1. **Is Prezto a viable plugin-bundle for zdot?**
2. **Does `compinit` need to move out of the OMZ bundle into a shared location?**

---

## 2. Prezto Overview

Prezto is a configuration framework for Zsh, older and more structured than OMZ. Its relevant internals:

### 2.1 Module structure

```
$ZPREZTODIR/modules/<name>/
├── init.zsh          # REQUIRED — sourced by pmodload
├── functions/        # Optional — autoloaded by pmodload before sourcing init.zsh
└── external/         # Optional — git submodule
```

### 2.2 pmodload — Prezto's module loader

`pmodload` is a public shell function, callable any time after `init.zsh` is sourced. It is idempotent (checks `zstyle ":prezto:module:$name" loaded`). Search path:

1. `$ZPREZTODIR/modules`
2. `$ZPREZTODIR/contrib`
3. User-supplied dirs via `zstyle ':prezto:load' pmodule-dirs`

`pmodload` has a `.plugin.zsh` fallback shim, meaning it can load OMZ-style plugins directly — this is important for coexistence analysis (§5).

### 2.3 Configuration

All Prezto configuration is via `zstyle` namespaced to `:prezto:module:<name>`. No global shell variable mutations are required by the framework itself (individual modules may set env vars).

### 2.4 compinit handling

Prezto does **not** call `compinit` from its top-level `init.zsh`. `compinit` is called only inside `modules/completion/init.zsh`, and only when the user includes `completion` in their module list. When it runs:

- Dump path: `${XDG_CACHE_HOME:-$HOME/.cache}/prezto/zcompdump`
- Cache strategy: if dump is < 20 hours old, `compinit -C` (skip security check); otherwise `compinit -i` (run full check)
- Dump is compiled to `.zwc` in a background subshell via `.zlogin` runcom

---

## 3. Viability Assessment

**Yes, Prezto is a viable plugin-bundle for zdot.** The conditions for viability are:

| Condition | Assessment |
|-----------|------------|
| Clear entry point | `init.zsh` — predictable, no magic discovery |
| Clean loader API | `pmodload <name>` — public, idempotent, documented |
| XDG-compatible paths | Yes, respects `XDG_CACHE_HOME` for compdump |
| No mandatory side effects at source time | Correct — sourcing `init.zsh` only sets up the loader; modules load on demand |
| `compinit` optional | Yes — only triggered if user loads the `completion` module |
| Reasonable fpath semantics | Modules append to `fpath` in a well-defined order |

### 3.1 Risks and constraints

- **Theme system conflict with OMZ**: Prezto's `prompt` module calls `promptinit` and sets `PROMPT` directly. If OMZ's theme system is also active, they will fight over `PROMPT`. Mitigation: document that the Prezto `prompt` module and OMZ theme system are mutually exclusive.
- **No auto-update mechanism**: Prezto has no built-in `upgrade` command equivalent to OMZ's. zdot's clone/pull mechanism would handle this uniformly.
- **Git submodule dependencies**: Some Prezto modules use `external/` submodules. The bundle's `clone` step must handle recursive clone.
- **`.zpreztorc` required**: Prezto's `init.zsh` unconditionally sources `~/.zpreztorc`. A zdot-managed install should provide a stub or configure this path.

---

## 4. Architecture: How a Prezto Bundle Would Work

### 4.1 Spec format

Proposed spec prefix: `pz:` (short, unambiguous, easy to type).

```zsh
zdot_use pz:modules/git
zdot_use pz:modules/completion
zdot_use pz:modules/syntax-highlighting
```

Alternatively `prezto:modules/git` is more explicit. Either works; `pz:` is recommended for ergonomics and is consistent with `omz:`.

### 4.2 Bundle handler interface

The bundle must implement the four required functions (see `docs/PLUGIN_IMPLEMENTATION.md`):

```zsh
# Returns 0 if this handler owns the spec
zdot_bundle_pz_match() {
    [[ "$1" == pz:* ]]
}

# Prints the filesystem path for the spec
zdot_bundle_pz_path() {
    local spec="${1#pz:}"        # strip prefix → modules/git
    echo "${_ZDOT_PZ_DIR}/${spec}"
}

# Ensures the module is on disk (Prezto itself must be cloned first)
zdot_bundle_pz_clone() {
    # Clone the Prezto repo if not present
    # Recurse submodules for modules with external/ dirs
    ...
}

# Sources / activates the module
zdot_bundle_pz_load() {
    local spec="${1#pz:}"
    local module_name="${spec#modules/}"   # e.g. "git"
    pmodload "$module_name"
}
```

Registration: `zdot_bundle_register pz` at end of `core/plugin-bundles/pz.zsh`.

### 4.3 Bootstrap sequence

Before any `pz:` module can load, Prezto's own `init.zsh` must be sourced. This bootstraps `pmodload` and the `zstyle` configuration surface. The bundle's init hook (registered on the `plugins-declared` phase) handles this:

```
plugins-declared
  └─► pz bundle: clone Prezto repo if absent
      pz bundle: source $ZPREZTODIR/init.zsh  (registers pmodload, reads .zpreztorc)

plugins-cloned
  └─► (no-op for pz — cloning done above)

plugins-loaded
  └─► each zdot_use pz:modules/X call → pmodload X
```

### 4.4 `.zpreztorc` strategy

Prezto's `init.zsh` sources `${ZDOTDIR:-$HOME}/.zpreztorc` unconditionally. For a zdot-managed install, two options:

**Option A — Stub `.zpreztorc`:** Ship a minimal `~/.zpreztorc` that sets only Prezto-internal zstyles (editor key bindings, color, etc.). Module loading is delegated to zdot (`zdot_use pz:...`) rather than Prezto's own `zstyle ':prezto:load' pmodules` mechanism.

**Option B — Redirect via `ZDOTDIR`:** If `ZDOTDIR` points to zdot's own dir, place a `zpreztorc` there. Prezto will pick it up via `${ZDOTDIR}/.zpreztorc`.

Option A is simpler and keeps the contract clear: zdot owns module loading; `.zpreztorc` only holds Prezto-internal configuration.

### 4.5 File location

```
core/plugin-bundles/
├── omz.zsh       # existing
└── pz.zsh        # new
```

Sourced in `zdot.zsh` immediately after `omz.zsh`:

```zsh
# zdot.zsh line 30 area
source "${zdot_core_dir}/plugin-bundles/omz.zsh"
source "${zdot_core_dir}/plugin-bundles/pz.zsh"   # add this
```

---

## 5. compinit Strategy

### 5.1 Current state

`compinit` machinery lives entirely in `core/plugin-bundles/omz.zsh`:

| Component | Location | Purpose |
|-----------|----------|---------|
| `compdef()` stub | `omz.zsh` | Queues `compdef` calls before compinit runs |
| `_ZDOT_COMPDEF_QUEUE` | `omz.zsh` | The queue array |
| `zdot_compinit_defer` | `omz.zsh` | Sets `_ZDOT_FPATH_READY=1` |
| `zdot_compinit_run` | `omz.zsh` | Calls compinit, replays queue |
| `zdot_ensure_compinit_during_precmd` | `omz.zsh` | precmd hook gating on `_ZDOT_FPATH_READY` |
| `zdot_enable_compinit_precmd` | `omz.zsh` | Registers the precmd hook |

`core/completions.zsh` handles only *completion registration* (the `zdot_completion_register_*` API for generating CLI completions). It contains no `compinit` logic and is not relevant here.

### 5.2 The problem

A Prezto `completion` module also needs `compinit`. If both OMZ and Prezto bundles are active simultaneously:

- OMZ calls `compinit` with its dump at `$ZSH_CACHE_DIR/.zcompdump-$HOST-$ZSH_VERSION`
- Prezto calls `compinit` again with its dump at `$XDG_CACHE_HOME/prezto/zcompdump`
- Result: `compinit` runs twice with different dump files — broken completion state

Even if only one bundle is active, coupling `compinit` to a specific bundle means the other bundle must either skip its own compinit or call zdot's — creating cross-bundle coupling.

### 5.3 Options

**Option 1 — Leave compinit in OMZ bundle, pz bundle calls `zdot_compinit_run`**

- Simplest short-term
- Hard cross-bundle dependency: pz bundle must know about omz internals
- Breaks if user uses pz bundle without omz bundle
- Not recommended

**Option 2 — Extract compinit to `core/plugin-bundles/shared.zsh` or `core/compinit.zsh`**

- Clean: one owner, no cross-bundle coupling
- Both bundles call `zdot_compinit_run`; the function is idempotent
- Dump path and staleness logic live in one place; can be made bundle-agnostic
- OMZ-specific staleness heuristic (git rev check) can remain as an OMZ-only override
- Recommended

**Option 3 — Each bundle manages its own compinit entirely**

- Duplicate logic; two different dump files
- Double `compinit` if both bundles active
- Not recommended

### 5.4 Recommendation: Extract to `core/compinit.zsh`

Create `core/compinit.zsh` with:

```zsh
# core/compinit.zsh — shared compinit machinery
#
# Provides:
#   zdot_compinit_run        — calls compinit once, replays compdef queue
#   zdot_compinit_defer      — signals fpath is ready
#   zdot_enable_compinit_precmd — registers precmd hook
#   compdef() stub           — queues calls before compinit runs

typeset -ga _ZDOT_COMPDEF_QUEUE
typeset -g  _ZDOT_FPATH_READY=0
typeset -g  _ZDOT_COMPINIT_DONE=0

# Compdump path — XDG-aware, not bundle-specific
_zdot_compdump_path() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zcompdump-${ZSH_VERSION}"
}
```

`zdot.zsh` sources it before bundles:

```zsh
source "${zdot_core_dir}/compinit.zsh"          # shared compinit
source "${zdot_core_dir}/plugin-bundles/omz.zsh"
source "${zdot_core_dir}/plugin-bundles/pz.zsh"
```

OMZ bundle retains its git-rev staleness heuristic as an optional override to `_zdot_compdump_path` or as a pre-compinit hook — but the core `compdef` stub and `compinit` call live in `core/compinit.zsh`.

**Impact on OMZ bundle:** The `compdef` stub, queue, `_ZDOT_FPATH_READY` flag, `zdot_compinit_run`, and precmd hook machinery move out. The OMZ-specific staleness check stays. This is a refactor, not a behaviour change — the OMZ bundle calls `zdot_compinit_run` exactly as today.

### 5.5 Answer to the driving question

**Yes, `compinit` needs to move out of the OMZ bundle** — not because it is broken there, but because:

1. A pz bundle also needs `compinit`, and there must be a single canonical caller
2. The compdump path is currently OMZ-specific; a shared path is preferable
3. The extraction is low-risk (pure refactor; no behaviour change for existing OMZ users)

---

## 6. OMZ + Prezto Coexistence

### 6.1 Can both bundles be active simultaneously?

Technically yes — `zdot_use omz:...` and `zdot_use pz:...` can coexist in `.zshrc`. However, specific module combinations will conflict:

| Conflict area | Details | Mitigation |
|---------------|---------|-----------|
| `compinit` | Both would call it if user loads both completion modules | Solved by §5.4: shared `zdot_compinit_run` is idempotent |
| `fpath` ordering | Both frameworks prepend to fpath; whichever loads first wins for a given completion | Load order in `.zshrc` determines winner; document this |
| Theme/prompt | OMZ theme system and Prezto `prompt` module both set `PROMPT` | Mutually exclusive; document that only one should set the prompt |
| `promptinit` | Prezto `prompt` module calls `promptinit`; OMZ does not | No conflict if Prezto `prompt` module is not loaded |

**Recommended coexistence posture:** Use one bundle as the primary framework. The other bundle is used only for its utility modules that do not touch the prompt or completion init. Document this clearly.

### 6.2 Practical use cases

- **Prezto-primary:** Load Prezto for its modules (git, editor, history, etc.). Do not load `pz:modules/prompt` if using oh-my-posh. Do not load `pz:modules/completion` if using OMZ for completions. Use `omz:` only for specific OMZ plugins with no Prezto equivalent.
- **OMZ-primary:** Same logic inverted. Use `pz:` for specific Prezto modules not covered by OMZ.
- **Prezto-only:** Full Prezto stack with no OMZ. The pz bundle is self-contained; OMZ bundle need not be sourced.

---

## 7. Required zdot Changes

### 7.1 Phase 1 — compinit extraction (prerequisite)

| Change | File | Type |
|--------|------|------|
| Create `core/compinit.zsh` with shared compinit machinery | new | Required |
| Remove compinit machinery from `core/plugin-bundles/omz.zsh` | edit | Required |
| Source `core/compinit.zsh` in `zdot.zsh` before bundles | edit | Required |
| Update `docs/PLUGIN_IMPLEMENTATION.md` compinit section | edit | Required |

### 7.2 Phase 2 — pz bundle

| Change | File | Type |
|--------|------|------|
| Create `core/plugin-bundles/pz.zsh` | new | Required |
| Source `pz.zsh` in `zdot.zsh` | edit | Required |
| Add `pz:` spec format to `docs/PLUGINS.md` | edit | Required |
| Add pz bundle docs to `docs/PLUGIN_IMPLEMENTATION.md` | edit | Required |
| Create `docs/design/prezto-bundle.md` (this document) | new | Done |

### 7.3 No public API changes required

The `zdot_use`, `zdot_bundle_register`, and four-function bundle handler contract are unchanged. The pz bundle is an additive implementation of the existing interface.

### 7.4 Interface additions (internal)

- `zdot_compinit_run` moves to `core/compinit.zsh` (callable by any bundle)
- `zdot_compinit_defer` moves to `core/compinit.zsh`
- `zdot_enable_compinit_precmd` moves to `core/compinit.zsh`
- New: `_zdot_compdump_path` function in `core/compinit.zsh` (XDG-aware, bundle-agnostic)

---

## 8. Implementation Plan

### Phase 1 — compinit extraction (independent value; do first)

Refactor only. No new user-visible features. Clears the path for any future bundle that needs `compinit`.

1. Write `core/compinit.zsh` by lifting the compdef stub, queue, `_ZDOT_FPATH_READY`, `zdot_compinit_run`, `zdot_compinit_defer`, `zdot_ensure_compinit_during_precmd`, and `zdot_enable_compinit_precmd` from `omz.zsh`
2. Replace the OMZ-specific compdump path with `_zdot_compdump_path` in `core/compinit.zsh`; make the OMZ-specific staleness check override it via a hook or subclassing pattern
3. Delete the moved code from `omz.zsh`; replace with calls to the shared functions
4. Add `source "${zdot_core_dir}/compinit.zsh"` in `zdot.zsh` before bundles
5. Verify existing OMZ-based shell still works; compdump path change is the only observable difference (update cache dir from OMZ-specific to `$XDG_CACHE_HOME/zdot/`)

> **Note on compdump path change:** Moving the dump from `$ZSH_CACHE_DIR/.zcompdump-$HOST-$ZSH_VERSION` to `$XDG_CACHE_HOME/zdot/zcompdump-$ZSH_VERSION` is a one-time migration. The old dump is ignored; a new one is generated on first shell open. This is safe — `compinit` regenerates the dump if it is absent or stale.

### Phase 2 — pz bundle

1. Create `core/plugin-bundles/pz.zsh` implementing the four handler functions
2. Handle Prezto repo clone (with `--recurse-submodules`)
3. Determine `.zpreztorc` strategy (Option A recommended — stub file)
4. Source `pz.zsh` in `zdot.zsh`
5. Write user-facing docs in `docs/PLUGINS.md`
6. Test with a representative set of Prezto modules (git, editor, history, syntax-highlighting)
7. Test pz-only configuration (no OMZ bundle active)
8. Test OMZ + pz coexistence with non-conflicting modules

### Phase 3 — polish (optional)

- Auto-discovery of bundle files in `core/plugin-bundles/` (currently planned but not implemented) — eliminates the explicit `source` lines in `zdot.zsh`
- Prezto contrib module support (third-party modules in additional dirs)
- `zdot update` support for Prezto repo + submodules

---

## 9. Summary

| Question | Answer |
|----------|--------|
| Is Prezto a viable plugin-bundle? | **Yes.** Clean API, idempotent loader, XDG-aware, optional compinit. |
| Does `compinit` need to move out of the OMZ bundle? | **Yes.** Extract to `core/compinit.zsh` before implementing the pz bundle. |
| Can OMZ and Prezto bundles coexist? | **Yes, with constraints.** Prompt and completion modules from each are mutually exclusive; utility modules can freely mix. |
| Public API changes needed? | **None.** Pz bundle implements the existing four-function handler contract. |
| Internal interface changes? | `compinit` machinery moves from `omz.zsh` to `core/compinit.zsh`; new `_zdot_compdump_path` helper. |
