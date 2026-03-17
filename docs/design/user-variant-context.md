# Design: User-Defined Variant Contexts

Date: 2026-03-16
Status: Implemented (2026-03-17)

Implementation notes:
- §5.3 `_zdot_variant_match` implemented as designed.
- §5.3 also added `_zdot_context_match` helper (symmetric refactor of the
  existing inline context-match loop in `zdot_build_execution_plan`).
- Group barrier variant inheritance added beyond the original design:
  `_zdot_init_resolve_groups` computes `_ZDOT_HOOK_VARIANTS` and
  `_ZDOT_HOOK_VARIANT_EXCLUDES` for synthetic begin/end barriers from
  their members (include = union, exclude = intersection), closing the
  gap where all-excluded members would leave barrier hooks active.
- §5.4 `_zdot_build_variant_provider_index` implemented as designed.
- §5.5 `_zdot_cache_context_suffix` extended to three-part key
  (`interactive_nonlogin_default`, etc.).  Cache version bumped required
  (pre-existing note; version currently "19").
- §5.6 `--variant`/`--variant-exclude` forwarded through
  `zdot_define_module` to all phase registrations.

---

## 1. The Problem

zdot's context model is currently a **two-dimensional pair**:

```
(interactive | noninteractive)  ×  (login | nonlogin)
```

This produces four possible runtime contexts.  The pair is detected
automatically from shell flags and never changes.

A third dimension is needed — a **user variant** — so that a user can
say "on my small laptop, skip heavy tools" or "at work, load extra
corporate modules".  This dimension is:

- **User-defined**: the label names are arbitrary strings, not a fixed
  enumeration.
- **Machine-specific**: typically detected by hostname, environment
  variable, or an explicit file.
- **Orthogonal**: independent from interactivity and login status.
- **Optional**: absent variant means "default" / no filtering applied.

---

## 2. Design Goals

1. A user can register hooks that only run in specific variants.
2. A user can register hooks that run in all-but certain variants.
3. Hooks with no variant constraint run in all variants (backward compat).
4. The variant propagates through the dependency / phase system exactly
   like the interactivity/login dimensions.
5. The execution plan cache is per (interactivity × login × variant).
6. The user sets the variant **before** `zdot_init` is called — zdot
   reads it once at plan-build time.
7. The variant identifier is a single word (alphanumeric + hyphens).
8. At most one variant is active at a time (single-dimension extension).

---

## 3. User API

### 3.1 Setting the Variant

The user sets the variant in `.zshrc` (or an early-sourced file) before
calling `zdot_init`.  zdot checks, in order:

1. `$ZDOT_VARIANT` environment variable (highest priority — allows
   override from parent process / wrapper scripts).
2. `zstyle ':zdot:variant' name <value>` — declarative config.
3. A user-supplied detection function `zdot_detect_variant` — if the
   function exists, zdot calls it; it must set `REPLY`.
4. If none of the above: variant is the empty string (default).

```zsh
# Option A — env var (set in .zshenv or a wrapper):
export ZDOT_VARIANT=work

# Option B — zstyle in .zshrc before zdot_init:
zstyle ':zdot:variant' name small

# Option C — logic function (most flexible), defined before zdot_init:
zdot_detect_variant() {
    case $HOST in
        (macbook-pro)   REPLY=work ;;
        (raspberry*)    REPLY=small ;;
        (*)             REPLY="" ;;
    esac
}
```

### 3.2 Registering a Hook with a Variant Constraint

A new `--variant` flag is added to `zdot_register_hook` (and by
extension to `zdot_simple_hook` / `zdot_define_module`).

```zsh
# Only run on the 'work' variant:
zdot_register_hook _vpn_init interactive noninteractive \
    --variant work \
    --requires brew-ready \
    --provides vpn-ready

# Run everywhere EXCEPT 'small':
zdot_register_hook _heavy_tools_init interactive \
    --variant-exclude small \
    --requires brew-ready

# No --variant flag = runs in ALL variants (unchanged semantics):
zdot_register_hook _xdg_init interactive noninteractive \
    --provides xdg-configured
```

`--variant` and `--variant-exclude` are mutually exclusive on a single
call.  Multiple `--variant` values can be listed to express "any of":

```zsh
zdot_register_hook _corp_tools_init interactive \
    --variant work --variant contractor \
    --requires brew-ready
```

### 3.3 Querying the Variant at Runtime

```zsh
zdot_variant()          # returns the active variant string (may be empty)
zdot_is_variant <name>  # returns 0/1 — guard inside hook bodies
```

---

## 4. Internal Representation

### 4.1 Global State (core/core.zsh additions)

```zsh
typeset -g _ZDOT_VARIANT=""            # Active variant string (empty = default)
typeset -g _ZDOT_VARIANT_DETECTED=0   # 1 once zdot_resolve_variant has run
```

### 4.2 Per-Hook Variant Storage (core/hooks.zsh additions)

```zsh
typeset -gA _ZDOT_HOOK_VARIANTS=()        # hook_id -> "v1 v2 ..."  (include list)
typeset -gA _ZDOT_HOOK_VARIANT_EXCLUDES=() # hook_id -> "v1 v2 ..." (exclude list)
```

Empty include list = matches all variants.

### 4.3 Phase Provider Registry (core/hooks.zsh)

The existing `_ZDOT_PHASE_PROVIDERS_BY_CONTEXT` key format is:

```
"<ctx_token>:<phase>"   e.g. "interactive:brew-ready"
```

With variants, this expands to a three-part key:

```
"<ctx_token>:<variant>:<phase>"   e.g. "interactive:work:vpn-ready"
```

For hooks with no variant constraint (empty variant), the key uses the
sentinel `"*"`:

```
"interactive:*:xdg-configured"
```

Look-up logic: when resolving a required phase in context `ctx` /
variant `v`, check both `"ctx:v:phase"` and `"ctx:*:phase"`.

---

## 5. Implementation Plan

### 5.1 core/ctx.zsh — variant detection

Add:

```zsh
# Resolve and store the active user variant.
# Called once from zdot_build_context (before plan build).
# Priority: $ZDOT_VARIANT env > zstyle ':zdot:variant' name > zdot_detect_variant()
zdot_resolve_variant() {
    if [[ -n "${ZDOT_VARIANT:-}" ]]; then
        _ZDOT_VARIANT="$ZDOT_VARIANT"
    elif zstyle -s ':zdot:variant' name _ZDOT_VARIANT; then
        : # zstyle set it
    elif (( ${+functions[zdot_detect_variant]} )); then
        REPLY=""
        zdot_detect_variant
        _ZDOT_VARIANT="$REPLY"
    else
        _ZDOT_VARIANT=""
    fi
    _ZDOT_VARIANT_DETECTED=1
}

zdot_variant() { print -r -- "$_ZDOT_VARIANT" }

zdot_is_variant() { [[ "$_ZDOT_VARIANT" == "$1" ]] }
```

Extend `zdot_build_context` to call `zdot_resolve_variant` and append
the variant to `_ZDOT_CURRENT_CONTEXT`:

```zsh
zdot_build_context() {
    # ... existing interactive/login logic ...

    zdot_resolve_variant

    if [[ -n "$_ZDOT_VARIANT" ]]; then
        _ZDOT_CURRENT_CONTEXT+=" variant:$_ZDOT_VARIANT"
    fi
    # When variant is empty, nothing extra is appended — backward compat.
}
```

The `variant:` prefix distinguishes variant tokens from interactivity /
login tokens in `_ZDOT_CURRENT_CONTEXT` and avoids collisions.

### 5.2 core/hooks.zsh — registration

In the pre-pass of `zdot_register_hook`, parse `--variant` and
`--variant-exclude`:

```zsh
local -a hook_variants=()
local -a hook_variant_excludes=()

# inside the _raw_args loop:
elif [[ ${_raw_args[$_i]} == --variant ]]; then
    (( _i++ ))
    hook_variants+=("${_raw_args[$_i]}")
elif [[ ${_raw_args[$_i]} == --variant-exclude ]]; then
    (( _i++ ))
    hook_variant_excludes+=("${_raw_args[$_i]}")
```

After hook_id assignment:

```zsh
_ZDOT_HOOK_VARIANTS[$hook_id]="${hook_variants[*]}"
_ZDOT_HOOK_VARIANT_EXCLUDES[$hook_id]="${hook_variant_excludes[*]}"
```

### 5.3 core/hooks.zsh — plan building

Add a helper function `_zdot_variant_match`:

```zsh
# Returns 0 if hook_id should run in the active variant.
_zdot_variant_match() {
    local hook_id="$1"
    local active_variant="$_ZDOT_VARIANT"

    local includes=(${=_ZDOT_HOOK_VARIANTS[$hook_id]})
    local excludes=(${=_ZDOT_HOOK_VARIANT_EXCLUDES[$hook_id]})

    # Exclude list takes priority.
    if (( ${#excludes} > 0 )); then
        [[ " ${excludes[*]} " =~ " ${active_variant} " ]] && return 1
    fi

    # If no include list: matches all variants.
    (( ${#includes} == 0 )) && return 0

    # Include list present: must match.
    [[ " ${includes[*]} " =~ " ${active_variant} " ]]
}
```

In `zdot_build_execution_plan`, after the existing `context_match`
check, add:

```zsh
# Variant filter
if ! _zdot_variant_match "$hook_id"; then
    continue
fi
```

### 5.4 core/hooks.zsh — phase provider registration

In `_zdot_register_phase_provider` (or wherever
`_ZDOT_PHASE_PROVIDERS_BY_CONTEXT` is written), use the three-part key:

```zsh
local variant_key="${_ZDOT_VARIANT:-*}"
# (At registration time _ZDOT_VARIANT may not be set yet — see §6 below)
```

**Problem**: hooks are registered at source time (before `zdot_init`
resolves the variant), but providers need to be indexed per-variant.

**Solution**: defer the variant-keyed index to plan-build time.  During
registration, store providers in the existing two-part key (or a
separate un-keyed store); at plan-build time (inside
`zdot_build_execution_plan`, after `zdot_resolve_variant` has run),
rebuild the lookup table with three-part keys.  This matches the
existing pattern where `_zdot_cache_context_suffix` is also called at
plan-build time.

Alternatively: register under a sentinel key and expand at plan-build.

Concrete approach — maintain the existing two-part registry for
registration; add a **variant-filtered view** at plan-build:

```zsh
# At plan-build time, after variant is resolved:
_zdot_build_variant_provider_index() {
    local active_variant="${_ZDOT_VARIANT:-}"
    typeset -gA _ZDOT_PHASE_PROVIDERS_ACTIVE=()

    for key in ${(k)_ZDOT_PHASE_PROVIDERS_BY_CONTEXT}; do
        local hook_id="${_ZDOT_PHASE_PROVIDERS_BY_CONTEXT[$key]}"
        # Only include providers whose hooks match the active variant
        if _zdot_variant_match "$hook_id"; then
            _ZDOT_PHASE_PROVIDERS_ACTIVE[$key]="$hook_id"
        fi
    done
}
```

Replace `_zdot_has_provider_in_contexts` lookups to use
`_ZDOT_PHASE_PROVIDERS_ACTIVE` instead of
`_ZDOT_PHASE_PROVIDERS_BY_CONTEXT` during plan building.

### 5.5 core/cache.zsh — context suffix

Extend `_zdot_cache_context_suffix` to include the variant:

```zsh
_zdot_cache_context_suffix() {
    local interactive_str login_str variant_str

    interactive_str=$([[ $_ZDOT_IS_INTERACTIVE -eq 1 ]] && echo interactive || echo noninteractive)
    login_str=$([[ $_ZDOT_IS_LOGIN -eq 1 ]] && echo login || echo nonlogin)
    variant_str="${_ZDOT_VARIANT:-default}"

    REPLY="${interactive_str}_${login_str}_${variant_str}"
}
```

Plan files become:
```
execution_plan_interactive_nonlogin_work.zsh
execution_plan_interactive_nonlogin_default.zsh
execution_plan_interactive_nonlogin_small.zsh
```

Cache invalidation: bump `_ZDOT_CACHE_VERSION` (a new variant dimension
means old plans must be discarded).

### 5.6 zdot_simple_hook / zdot_define_module passthrough

Both sugar functions call `zdot_register_hook` internally; they need to
accept and forward `--variant` / `--variant-exclude`:

```zsh
# zdot_simple_hook: add to the flags forwarded to zdot_register_hook
# zdot_define_module: add to the per-phase flags parsed and forwarded
```

The `zdot_define_module` macro has a richer argument structure (separate
flags for each phase); `--variant` can be applied at the module level
(propagated to all phases) or overridden per-phase.

---

## 6. Registration-Time vs Plan-Time Concerns

| Concern | Time | Notes |
|---|---|---|
| `_ZDOT_HOOK_VARIANTS` populated | Registration (source time) | Always safe |
| `_ZDOT_VARIANT` resolved | `zdot_build_context()` — plan-build | Before Kahn's sort |
| Provider index built | `zdot_build_execution_plan()` | After variant resolved |
| Cache suffix computed | Same as above | Uses `_ZDOT_VARIANT` |
| Cache saved | End of `zdot_init` | Three-part suffix |

No changes needed to deferred execution: by the time deferred hooks
run, `_ZDOT_VARIANT` is already set and `_ZDOT_PHASES_PROVIDED` is
maintained correctly.

---

## 7. Introspection / CLI

The existing `zdot_hooks_list` and `zdot_show_plan` functions should
display the active variant and, per hook, any variant constraints:

```
zdot hooks list
  hook_5  _vpn_init         [interactive noninteractive] [variant: work]  requires: brew-ready
  hook_6  _heavy_tools_init [interactive]               [variant-excl: small] requires: brew-ready

Active context: interactive nonlogin  variant: work
```

---

## 8. Backward Compatibility

- Hooks with no `--variant` / `--variant-exclude` flags are unaffected.
- `_ZDOT_CURRENT_CONTEXT` gains an optional third token only when
  `_ZDOT_VARIANT` is non-empty, so existing consumers that iterate
  `current_contexts` and match `interactive` / `noninteractive` /
  `login` / `nonlogin` still work — `variant:work` simply never matches
  those patterns.
- Cache files with old two-part names are superseded by new three-part
  names after the version bump; old files are stale and harmlessly
  ignored.

---

## 9. Open Questions

1. **Multiple variants / variant sets**: Should a user be able to
   combine variants (e.g. `work+small`)?  Current design: single
   variant, composable via hyphen (`work-small`).

2. **Variant inheritance**: Should `work` automatically include all
   hooks for the default variant?  Current design: yes, because hooks
   with no `--variant` flag match all variants.

3. **Runtime variant changes**: Out of scope.  Variant is immutable per
   shell session.

4. **zdot_defer_order interaction**: Ordering constraints between hooks
   that have different variant constraints — are they silently ignored
   if one hook is filtered out?  Proposed: yes, same as if the hook
   were filtered by context.

5. **zdot_detect_variant error handling**: What if the function throws?
   Proposed: log a warning and fall back to empty variant.

---

## 10. File Change Summary

| File | Change |
|---|---|
| `core/ctx.zsh` | Add `zdot_resolve_variant`, `zdot_variant`, `zdot_is_variant`; extend `zdot_build_context` |
| `core/core.zsh` | Add `_ZDOT_VARIANT`, `_ZDOT_VARIANT_DETECTED` globals |
| `core/hooks.zsh` | Parse `--variant`/`--variant-exclude`; add `_zdot_variant_match`; add `_zdot_build_variant_provider_index`; filter in plan builder |
| `core/cache.zsh` | Extend `_zdot_cache_context_suffix`; bump `_ZDOT_CACHE_VERSION` |
| `core/modules.zsh` | Forward `--variant`/`--variant-exclude` through `zdot_define_module` |
| `core/functions/zdot_hooks_list` | Display variant constraints |
| `core/functions/zdot_show_plan` | Show active variant |
| `docs/IMPLEMENTATION.md` | Document new dimension |
| `README.md` | User-facing variant docs |
