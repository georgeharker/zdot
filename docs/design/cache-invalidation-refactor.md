# Cache Invalidation Refactor — Design Proposal

**Status:** AWAITING APPROVAL  
**Prerequisite reading:** `omz-integration-analysis.md`

---

## Goals

1. **Modularize** inline stampfile/serialization blocks in `omz.zsh` into named functions with single responsibilities.
2. **Fix Gap 1 (fpath invalidation):** Replace the `grep`/`cut`/stampfile mechanism with an F2 metadata file (`typeset -p` serialization), mirroring the `use-omz` reference implementation exactly.
3. **Fix Gap 2 (precmd safety net):** Fix `zdot_ensure_compinit_during_precmd` — remove the erroneous refresh-gate; run compinit unconditionally if `_ZDOT_COMPINIT_DONE` is unset; self-remove the hook.
4. **Wire `cache.zsh` ↔ `plugins.zsh`:** Add `zdot_plugins_have_changed` to `plugins.zsh`; call it from `load_cache` so plugin rev changes invalidate the execution plan and signal the compdump.
5. **Wire `cache.zsh` → `omz.zsh`:** When `cache.zsh` determines a rebuild is needed, set `_ZDOT_FORCE_COMPDUMP_REFRESH=1` so `omz.zsh` skips its own metadata comparison and runs compinit unconditionally.

No implementation changes are made until this document is approved.

---

## Separation of Concerns (unchanged from prior analysis)

| Layer | Owns |
|-------|------|
| `cache.zsh` | `.zwc` invalidation, execution plan cache, source-file mtime detection, plugin-rev change detection (via delegation), compdump pre-invalidation signal |
| `plugins.zsh` | Plugin rev change detection (`zdot_plugins_have_changed`) |
| `omz.zsh` | Compdump lifecycle: compinit, F2 metadata file, compdef queue, precmd safety net |

`cache.zsh` does **not** manage the compdump directly. It only sets `_ZDOT_FORCE_COMPDUMP_REFRESH=1` as a signal.

---

## Change 1 — `omz.zsh`: Replace `zdot_compdump_needs_refresh` with F2 pattern

### Current (remove)

`zdot_compdump_needs_refresh` (L170–216): uses `grep`/`cut` to read `#omz revision:` from the compdump file and a separate `.rev` stampfile.

Also remove: the inline blocks in `zdot_compinit_defer` (L250–262) and `zdot_compinit_reexec` (L292–303) that write the `#omz revision:` annotation and `.rev` stampfile.

### Replacement: two new functions

#### `zdot_omz_compdump_write_meta`

Writes the F2 metadata file after compinit runs. Called by both `zdot_compinit_defer` and `zdot_compinit_reexec` in place of their current inline blocks.

```zsh
# Location of the F2 metadata file.
# Mirrors $ZSH_CACHE_DIR/zcompdump-metadata.zsh in the use-omz reference.
typeset -g _ZDOT_COMPDUMP_META_FILE

zdot_omz_compdump_meta_init() {
    [[ -n "$_ZDOT_COMPDUMP_META_FILE" ]] && return 0
    local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/omz"
    [[ ! -d "$cache_dir" ]] && mkdir -p "$cache_dir"
    _ZDOT_COMPDUMP_META_FILE="${cache_dir}/zcompdump-metadata.zsh"
}

# Write F2 metadata file. Called after every successful compinit run.
zdot_omz_compdump_write_meta() {
    zdot_omz_compdump_meta_init
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"

    typeset -g  ZSH_COMPDUMP_REV
    typeset -ga ZSH_COMPDUMP_FPATH

    ZSH_COMPDUMP_REV=$(cd "$cache" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
    ZSH_COMPDUMP_FPATH=($fpath)

    { typeset -p ZSH_COMPDUMP_REV; typeset -p ZSH_COMPDUMP_FPATH } >| "$_ZDOT_COMPDUMP_META_FILE"
}
```

#### `zdot_omz_compdump_needs_refresh` (replaces `zdot_compdump_needs_refresh`)

Reads the F2 metadata file to compare stored vs. current rev+fpath. Identical logic to `has-zcompdump-expired` in `use-omz`, adapted for zdot naming.

```zsh
# Returns 0 (needs refresh) or 1 (up to date).
# Also checks _ZDOT_FORCE_COMPDUMP_REFRESH set by cache.zsh.
zdot_omz_compdump_needs_refresh() {
    zdot_init_compfile
    zdot_omz_compdump_meta_init

    local compfile="$_ZDOT_COMPFILE"

    # File absent — always refresh.
    [[ ! -f "$compfile" ]] && return 0

    # cache.zsh signalled a forced refresh.
    [[ -n "$_ZDOT_FORCE_COMPDUMP_REFRESH" ]] && return 0

    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    local current_rev current_fpath
    current_rev=$(cd "$cache" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
    current_fpath=($fpath)

    typeset -g  ZSH_COMPDUMP_REV
    typeset -ga ZSH_COMPDUMP_FPATH
    [[ -r "$_ZDOT_COMPDUMP_META_FILE" ]] && source "$_ZDOT_COMPDUMP_META_FILE"

    if [[ "$current_rev"   != "$ZSH_COMPDUMP_REV"   ]] ||
       [[ "$current_fpath" != "$ZSH_COMPDUMP_FPATH" ]]; then
        return 0  # needs refresh
    fi

    return 1  # up to date
}
```

**Note:** `zdot_omz_compdump_write_meta` writes the metadata file **after** compinit runs (not during the check). This differs from `use-omz`, which writes during the check. We keep the write-after-compinit ordering to match our existing `zdot_compinit_defer` / `zdot_compinit_reexec` structure.

### Recompile helper (extract inline block)

The `zrecompile` block is duplicated in both `zdot_compinit_defer` (L264–272) and `zdot_compinit_reexec` (L305–313). Extract into a named function:

```zsh
zdot_omz_compdump_recompile() {
    local compfile="$_ZDOT_COMPFILE"
    {
        if [[ -s "$compfile" && (! -s "${compfile}.zwc" || "$compfile" -nt "${compfile}.zwc") ]]; then
            if command mkdir "${compfile}.lock" 2>/dev/null; then
                autoload -U zrecompile
                zrecompile -q -p "$compfile"
                command rm -rf "${compfile}.zwc.old" "${compfile}.lock" 2>/dev/null
            fi
        fi
    } &!
}
```

### Updated `zdot_compinit_defer` and `zdot_compinit_reexec`

After extraction, the compinit functions call the helpers instead of inlining:

```zsh
# zdot_compinit_defer — do_compinit=1 branch becomes:
compinit -i -d "$compfile"   # (or -u if ZSH_DISABLE_COMPFIX)
zdot_omz_compdump_write_meta
zdot_omz_compdump_recompile

# zdot_compinit_reexec becomes:
compinit -i -d "$compfile"   # (or -u)
zdot_omz_compdump_write_meta
zdot_omz_compdump_recompile
```

Also update the refresh check call site in `zdot_compinit_defer` (L238):
```zsh
# Before:
if [[ -f "$compfile" ]] && ! zdot_compdump_needs_refresh; then
# After:
if [[ -f "$compfile" ]] && ! zdot_omz_compdump_needs_refresh; then
```

### Files to clean up after Change 1

- Remove `_ZDOT_COMPINIT_DEFERRED` if it is no longer needed after the refactor (verify at implementation time).
- Remove the `.rev` stampfile — it is superseded by the F2 metadata file. Any existing `*.rev` files can be left on disk (they are harmless) or deleted by `zdot_cache_invalidate`.

---

## Change 2 — `omz.zsh`: Fix `zdot_ensure_compinit_during_precmd` (Gap 2 / P1)

### Current bug (L325–334)

```zsh
zdot_ensure_compinit_during_precmd() {
    [[ $_ZDOT_COMPINIT_CHECKED_DURING_PRECMD -eq 1 ]] && return 0
    [[ -n "$_ZDOT_COMPINIT_DONE" ]] && return 0
    _ZDOT_COMPINIT_CHECKED_DURING_PRECMD=1
    if zdot_compdump_needs_refresh; then   # BUG: gates on refresh check
        zdot_compinit_reexec               # silently skipped if compdump is fresh
    fi
}
```

If `zsh-defer` never fires (fast prompt, no deferred slot), `_ZDOT_COMPINIT_DONE` is unset and we reach the refresh check. But if the compdump happens to be up-to-date, `zdot_compdump_needs_refresh` returns 1 and compinit is silently skipped entirely — leaving completions broken.

### Fix (P1 pattern, mirrors `use-omz`)

```zsh
zdot_ensure_compinit_during_precmd() {
    # If compinit already ran, nothing to do.
    [[ -n "$_ZDOT_COMPINIT_DONE" ]] && {
        add-zsh-hook -d precmd zdot_ensure_compinit_during_precmd
        return 0
    }

    # compinit was never called (zsh-defer didn't fire) — run it now
    # unconditionally, regardless of whether the compdump is fresh.
    zdot_compinit_reexec

    # Always self-remove; this hook must not fire more than once.
    add-zsh-hook -d precmd zdot_ensure_compinit_during_precmd
}
```

Also remove `_ZDOT_COMPINIT_CHECKED_DURING_PRECMD` — it is no longer needed because the hook self-removes.

---

## Change 3 — `plugins.zsh`: Add `zdot_plugins_have_changed`

A new public function that `cache.zsh` can call to ask "have any plugin revs changed since the plan was last saved?"

The function compares the current git HEAD of each cloned plugin against a stamp stored in `_ZDOT_CACHE_DIR/plugin-revs.zsh`. The stamp file uses `typeset -p` serialization (consistent with F2).

```zsh
# Stamp file location — set during plugins init.
typeset -g _ZDOT_PLUGINS_REV_STAMP

_zdot_plugins_rev_stamp_init() {
    [[ -n "$_ZDOT_PLUGINS_REV_STAMP" ]] && return 0
    local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot"
    _ZDOT_PLUGINS_REV_STAMP="${cache_dir}/plugin-revs.zsh"
}

# Returns 0 if any plugin rev has changed since last stamp, 1 if all match.
# Side effect: updates the stamp file when a change is detected.
zdot_plugins_have_changed() {
    _zdot_plugins_rev_stamp_init

    typeset -gA _ZDOT_PLUGINS_SAVED_REV
    [[ -r "$_ZDOT_PLUGINS_REV_STAMP" ]] && source "$_ZDOT_PLUGINS_REV_STAMP"

    local changed=0
    local spec path current_rev
    typeset -gA _ZDOT_PLUGINS_CURRENT_REV

    for spec in ${(k)_ZDOT_PLUGINS_PATH}; do
        path="${_ZDOT_PLUGINS_PATH[$spec]}"
        [[ -d "$path/.git" ]] || continue
        current_rev=$(git -C "$path" rev-parse HEAD 2>/dev/null)
        _ZDOT_PLUGINS_CURRENT_REV[$spec]="$current_rev"
        if [[ "$current_rev" != "${_ZDOT_PLUGINS_SAVED_REV[$spec]}" ]]; then
            changed=1
        fi
    done

    if [[ $changed -eq 1 ]]; then
        _ZDOT_PLUGINS_SAVED_REV=("${(kv)_ZDOT_PLUGINS_CURRENT_REV[@]}")
        { typeset -p _ZDOT_PLUGINS_SAVED_REV } >| "$_ZDOT_PLUGINS_REV_STAMP"
        return 0  # changed
    fi

    return 1  # no change
}
```

---

## Change 4 — `cache.zsh`: Call `zdot_plugins_have_changed`, set force-refresh flag

### In `load_cache`, after the existing mtime checks (L363–380)

Add:

```zsh
# Check for plugin rev changes.
# zdot_plugins_have_changed is defined in core/plugins.zsh which is always
# sourced before cache.zsh evaluates the plan.
if (( ${+functions[zdot_plugins_have_changed]} )) && zdot_plugins_have_changed; then
    # Signal omz.zsh to skip its own metadata comparison and re-run compinit.
    typeset -g _ZDOT_FORCE_COMPDUMP_REFRESH=1
    return 1  # invalidate plan
fi
```

### In `zdot_cache_invalidate` — clean up F2 artifacts

```zsh
# Remove F2 metadata file (omz.zsh will recreate it on next compinit).
if (( ${+_ZDOT_COMPDUMP_META_FILE} )) && [[ -f "$_ZDOT_COMPDUMP_META_FILE" ]]; then
    rm -f "$_ZDOT_COMPDUMP_META_FILE"
fi

# Remove plugin rev stamp (plugins.zsh will recreate it).
if (( ${+_ZDOT_PLUGINS_REV_STAMP} )) && [[ -f "$_ZDOT_PLUGINS_REV_STAMP" ]]; then
    rm -f "$_ZDOT_PLUGINS_REV_STAMP"
fi
```

---

## File-level summary

| File | Changes |
|------|---------|
| `core/plugin-bundles/omz.zsh` | Remove `zdot_compdump_needs_refresh`; add `zdot_omz_compdump_meta_init`, `zdot_omz_compdump_write_meta`, `zdot_omz_compdump_needs_refresh`, `zdot_omz_compdump_recompile`; extract inline blocks from `zdot_compinit_defer` + `zdot_compinit_reexec`; fix `zdot_ensure_compinit_during_precmd` (P1); remove `_ZDOT_COMPINIT_CHECKED_DURING_PRECMD` |
| `core/plugins.zsh` | Add `_zdot_plugins_rev_stamp_init`, `zdot_plugins_have_changed` |
| `core/cache.zsh` | Add `zdot_plugins_have_changed` call in `load_cache`; set `_ZDOT_FORCE_COMPDUMP_REFRESH=1` on plugin change; clean up F2 artifacts in `zdot_cache_invalidate` |

---

## What is NOT changing

- The compdef queue and its `(z)` flag serialization — left as-is in `omz.zsh`
- `zdot_has_zcompdump_expired` (age-based check) — left as-is
- `zdot_init_compfile` — left as-is
- The `_zdot_cache_context_suffix` / `zdot_cache_save_plan` logic — no changes
- The co-located `.zwc` compilation system

---

## Open question (non-blocking)

**Is the compdef queue OMZ-specific or general?**  
The queue intercepts `compdef` calls before compinit. The mechanism is general but the only current consumer is OMZ plugins. Refactoring this into a separate concern is deferred — not part of this change.
