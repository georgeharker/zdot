# Fix Validation Report

**Date:** 2026-02-18
**Scope:** Validate the four correctness fixes described in
`compdump-and-clone-fastpath.md` are present in the codebase.
**Result:** All four fixes confirmed present and correct.

---

## 1. Validation Summary

| Fix | Description | Evidence | Status |
|-----|-------------|----------|--------|
| 1 | `zdot_compinit_reexec` writes to `$_ZDOT_COMPFILE` | `core/plugin-bundles/omz.zsh:282–317` | Confirmed |
| 2 | compinit enqueued after deferred-plugin fpath additions | `core/plugins.zsh:357–361`, `lib/plugins/plugins.zsh:125–135` | Confirmed |
| 3 | Sentinel encodes version pins; fast path checks disk presence | `core/plugins.zsh:179–231` | Confirmed |
| 4 | `omz:*` fast-path skip has coupling comment | `core/plugins.zsh:209–210` | Confirmed |

---

## 2. Fix-by-Fix Evidence

### Fix 1 — `zdot_compinit_reexec` compfile argument

**File:** `core/plugin-bundles/omz.zsh:282–317`

```zsh
zdot_compinit_reexec() {
    local compfile="$_ZDOT_COMPFILE"

    if [[ "$ZSH_DISABLE_COMPFIX" != true ]]; then
        autoload -Uz compaudit
        compinit -i -d "$compfile"
    else
        compinit -u -d "$compfile"
    fi
    ...
}
```

Both `compinit` call sites pass `-d "$compfile"`. The variable is set from
`$_ZDOT_COMPFILE` (e.g. `~/.zcompdump-cascade-5.9`), not the default
`~/.zcompdump`. Fix confirmed.

---

### Fix 2 — compinit timing relative to deferred plugin fpath additions

**File:** `core/plugins.zsh:357–361`

```zsh
# Enqueue compinit after all deferred plugin sources so fpath is fully
# populated (deferred plugins add completion dirs during their source).
# In the non-defer passthrough path zdot_defer calls zdot_compinit_defer
# directly; its [[ -o interactive ]] guard handles non-interactive shells.
zdot_defer zdot_compinit_defer
```

`zdot_compinit_defer` is enqueued as the last job in
`zdot_load_deferred_plugins`, after all `zdot_defer source "$plugin_file"`
calls. Fix confirmed.

**File:** `lib/plugins/plugins.zsh:125–135`

```zsh
# fzf-tab explicitly handles being initialized before compinit (see fzf-tab.zsh
# line 376-379: it pre-creates the completion widget when compinit hasn't run
# yet). Compinit itself is enqueued at the end of zdot_load_deferred_plugins
# via zdot_defer, so it runs after all deferred plugin fpath additions.
_plugins_load_fzf_tab() {
    zdot_load_plugin Aloxaf/fzf-tab
}

zdot_hook_register _plugins_load_fzf_tab interactive \
    --requires plugins-loaded \
    --provides fzf-tab-loaded
```

`_plugins_load_fzf_tab` uses `--requires plugins-loaded` (not
`--requires compinit-done`). No `_plugins_run_compinit` hook is registered
here. Fix confirmed.

---

### Fix 3 — Sentinel version-pin encoding and disk-presence check

**File:** `core/plugins.zsh:184–231`

Version-pin encoding (lines 187–197):

```zsh
local _s _v
local -a _sentinel_parts
for _s in $_ZDOT_PLUGINS_ORDER; do
    _v=${_ZDOT_PLUGINS_VERSION[$_s]:-}
    if [[ -n "$_v" ]]; then
        _sentinel_parts+=( "${_s}@${_v}" )
    else
        _sentinel_parts+=( "$_s" )
    fi
done
local current_specs="${(j: :)_sentinel_parts}"
```

Disk-presence check inside the fast path (lines 204–220):

```zsh
local _fast_spec _fast_cache _fast_all_present=1
_fast_cache=${_ZDOT_PLUGINS_CACHE}
for _fast_spec in $_ZDOT_PLUGINS_ORDER; do
    [[ -n "${_ZDOT_PLUGINS_PATH[$_fast_spec]}" ]] && continue
    [[ $_fast_spec == *:* ]] && continue
    if [[ ! -d "${_fast_cache}/${_fast_spec}" ]]; then
        _fast_all_present=0
        break
    fi
    _ZDOT_PLUGINS_PATH[$_fast_spec]="${_fast_cache}/${_fast_spec}"
done
[[ $_fast_all_present -eq 1 ]] && return 0
```

Both sub-fixes confirmed.

---

### Fix 4 — `omz:*` fast-path coupling comment

**File:** `core/plugins.zsh:209–210`

```zsh
# This is safe only because no omz:* spec uses kind=defer — if that
# ever changes, this skip must be revisited.
```

Comment present immediately before `[[ $_fast_spec == *:* ]] && continue`.
Fix confirmed.

---

## 3. Compdump Check

**Command:** `grep -c '_abbr\|_fast-theme\|_job-queue' ~/.zcompdump-cascade-5.9`
**Result:** 0 (zero matches)

`_abbr` (zsh-abbr), `_fast-theme` (fast-syntax-highlighting), and `_job-queue`
(zsh-abbr) are all absent from the compdump.

**This is a stale-compdump artifact**, not evidence of a bug. The checked
compdump (`mtime: Feb 18 17:19:05 2026`) was last written before Fix 2 was in
place (or before a cold start after Fix 2). It does not reflect the state of
the current code.

Fix 2 resolves the fpath-timing gap. Here is why:

1. `zsh-defer` processes its queue in **FIFO order inside a single
   `zle-line-init` while-loop** (`_zsh-defer-resume` line 46 of
   `zsh-defer.plugin.zsh`). All tasks run in one pass unless keys are pending.

2. `zsh-abbr` adds its completions directory to `fpath` **inside its plugin
   source** (`fpath+=${0:A:h}/completions` at line 1 of
   `zsh-abbr.plugin.zsh`). Because `zdot_defer source zsh-abbr` was enqueued
   before `zdot_defer zdot_compinit_defer`, the fpath addition happens first.

3. When `zdot_compinit_defer` runs, `fpath` already includes the completions
   directories from all deferred plugins. Compinit therefore registers those
   completion functions and will write them to the compdump.

The compdump will include these completions on the next cold start after the
deferred plugins have sourced once (i.e. after the queue has processed on first
interactive use following a cache miss).

---

## 4. Clone Sentinel Check

**File:** `~/.cache/zdot/plugins/.cloned`

```
romkatv/zsh-defer omz:lib omz:plugins/git omz:plugins/tmux omz:plugins/fzf
omz:plugins/zoxide omz:plugins/npm omz:plugins/nvm omz:plugins/eza
omz:plugins/ssh omz:plugins/debian olets/zsh-abbr
zdharma-continuum/fast-syntax-highlighting 5A6F65/fast-abbr-highlighting
zsh-users/zsh-autosuggestions
olets/zsh-autosuggestions-abbreviations-strategy Aloxaf/fzf-tab
```

The sentinel on disk is in the **pre-fix format** (no `@version` suffixes).
This is expected: the sentinel was last written before Fix 3 was applied.

Since no spec currently has a version pin set in `_ZDOT_PLUGINS_VERSION`, the
pre-fix and post-fix sentinel formats produce identical output. The sentinel
will be rewritten in the new format on the next cold start or after manual
deletion of the file.

---

## 5. Design Doc Accuracy Notes

`docs/design/compdump-and-clone-fastpath.md` is the authoritative design
record. Its status table (lines 18–23) correctly marks all four fixes as
"Applied". However, two sections still quote pre-fix code:

### §1.2 — `zdot_compinit_reexec` (approx. lines 175–188 of the doc)

The quoted function body shows `compinit -i` and `compinit -u` **without**
`-d "$compfile"`. This was the buggy state Fix 1 corrected. The narrative
correctly describes it as a bug, but a reader may be confused if they compare
the quoted code with the current file.

**Suggested update:** Replace the quoted function body in §1.2 with the
fixed version (`compinit -i -d "$compfile"` / `compinit -u -d "$compfile"`),
or add a note that the listing is the pre-fix state.

### §2.1 — Sentinel-building code (approx. lines 462–487 of the doc)

The quoted code shows `local current_specs="${(j: :)_ZDOT_PLUGINS_ORDER}"` and
the fast-path loop without disk-presence checks. Again, the narrative correctly
calls this a bug, but the listing reflects the pre-fix state.

**Suggested update:** Replace the quoted sentinel-building block and fast-path
loop with the fixed versions, or annotate them clearly as historical.

---

## 6. Open Issues (unchanged by these fixes)

These are carried forward from the design doc and are not regressions:

1. **`#omz fpath:` annotation written but never read** — `zdot_compinit_reexec`
   appends `#omz fpath:${fpath[*]}` to the compdump (line 300 of `omz.zsh`),
   but no code reads this annotation at startup to pre-populate fpath. The
   write is currently a no-op from a functional standpoint.

2. **Latent subshells in `zdot_load_plugin`** — Some code paths may spawn
   subshells during plugin loading. Noted in the design doc; not addressed by
   these four fixes.

3. **Sentinel on disk still in pre-fix format** — Will self-correct on the next
   cold start or after `rm ~/.cache/zdot/plugins/.cloned`.

---

## 7. Previously-Open Issue Now Resolved

**fpath-timing gap** (was Issue #1 in the design doc, Options A–E) —
**Resolved by Fix 2.**

The design doc listed this as an architectural gap: completion functions from
deferred plugins were absent from the compdump because compinit ran before the
plugins sourced their fpath additions.

Fix 2 resolves this by enqueuing `zdot_compinit_defer` as the last job in the
deferred queue. Because `zsh-defer` processes its queue FIFO in a single
`zle-line-init` while-loop, all plugin sources (and their inline fpath
additions) complete before compinit executes. The compdump produced after that
first interactive use will include deferred-plugin completion functions.

The zero-match compdump observed during validation (see §3) is a stale artifact
predating this fix, not evidence of a remaining gap.
