# Design Analysis: Compdump Architecture and Clone Fast Path

This document is a grounded analysis of two subsystems: compdump lifecycle
management and the clone fast path. It quotes actual function bodies with exact
line number citations, traces execution paths step by step, and reports measured
results where observable behavior has been confirmed. Options are presented with
tradeoffs; no recommendation is made.

All line numbers refer to the state of the codebase after the performance fixes
applied in the plugin system refactor.

---

## Status of Fixes

All four correctness bugs identified in this document have been resolved:

| Fix | Description | Status |
|-----|-------------|--------|
| 1 | `zdot_compinit_reexec` wrote to `~/.zcompdump` instead of `$_ZDOT_COMPFILE` | **Applied** (`core/plugin-bundles/omz.zsh`) |
| 2 | compinit ran before deferred plugins added fpath contributions; `abbr<TAB>` broken | **Applied** (`core/plugins.zsh`, `lib/plugins/plugins.zsh`) |
| 3 | Sentinel did not encode version pins; version-pin changes were silently ignored | **Applied** (`core/plugins.zsh`) |
| 4 | `[[ $_fast_spec == *:* ]] && continue` had no comment explaining the hidden `kind=defer` assumption | **Applied** (`core/plugins.zsh`) |

Fix 2 implementation: `zdot_defer zdot_compinit_defer` is enqueued as the last
job inside `zdot_load_deferred_plugins`, after all `zdot_defer source
"$plugin_file"` calls. Since `zsh-defer` processes its queue in order, compinit
runs after all deferred plugin sources and their fpath additions.

Fix 3 implementation: `current_specs` is now built by iterating
`_ZDOT_PLUGINS_ORDER` and appending `@version` when `_ZDOT_PLUGINS_VERSION[$s]`
is non-empty. Sentinel format changes from `user/repo ...` to
`user/repo@vtag ...` for pinned specs. Additionally, the fast path now verifies
that each expected plugin directory exists on disk; if any is absent, it falls
through to the slow path rather than silently setting a path to a nonexistent
directory.

---

## 1. Compdump Architecture

### 1.1 Phase Chain and Compinit Timing

The hook phase chain through plugin loading is, in order:

```
xdg-configured
  → plugins-declared        (_plugins_configure)
    → plugins-cloned         (zdot_plugins_clone_all)
      → omz-plugins-loaded   (_plugins_load_omz)
        → plugins-loaded      (_plugins_load_deferred)
          → fzf-tab-loaded    (_plugins_load_fzf_tab — interactive only)
            → plugins-post-configured
```

`zdot_compinit_defer` is called as the **last statement** of `_plugins_load_omz`
in `lib/plugins/plugins.zsh:100`. The exact body of that function
(`lib/plugins/plugins.zsh:84–101`):

```zsh
_plugins_load_omz() {
    zdot_load_plugin omz:lib
    zdot_load_plugin omz:plugins/git
    zdot_load_plugin omz:plugins/tmux
    zdot_has_tty && zdot_load_plugin omz:plugins/fzf
    zdot_load_plugin omz:plugins/zoxide
    zdot_load_plugin omz:plugins/npm
    zdot_load_plugin omz:plugins/nvm
    zdot_load_plugin omz:plugins/eza
    zdot_load_plugin omz:plugins/ssh
    if [[ $(uname -v 2>/dev/null) == *"Debian"* || $(uname -v 2>/dev/null) == *"Ubuntu"* ]]; then
        zdot_load_plugin omz:plugins/debian
    fi
    zdot_compinit_defer    # line 100
}
```

`_plugins_load_omz` provides the `omz-plugins-loaded` phase. When it returns,
the hook system drives `plugins-loaded`, which runs `_plugins_load_deferred`
(`lib/plugins/plugins.zsh:113–120`):

```zsh
_plugins_load_deferred() {
    local spec
    for spec in $_ZDOT_PLUGINS_ORDER; do
        [[ ${_ZDOT_PLUGINS_KIND[$spec]:-} == defer ]] || continue
        zdot_load_deferred_plugins $spec
    done
}
```

This loads all `kind=defer` plugins — `olets/zsh-abbr`,
`zdharma-continuum/fast-syntax-highlighting`, `zsh-users/zsh-autosuggestions`,
and others. These plugins run their `.plugin.zsh` files, including any
`fpath+=` lines, **after compinit has already run**.

### 1.2 The Three Compinit Functions

#### `zdot_compdump_needs_refresh` (`core/plugin-bundles/omz.zsh:170–216`)

Decides whether compinit must re-run. Returns 0 (needs refresh) or 1 (fresh).

**Fast path** (lines 185–196): if `$compfile.rev` (the stamp file) exists, read
the `#omz revision:` annotation from the compdump via `grep` and compare
against the stamp file's contents using `$(<stampfile)` (no subshell). Return 1
immediately if they match — no git subprocess.

**Slow path** (lines 200–213): stamp file absent or unreadable. Runs
`git rev-parse HEAD` in a subshell inside `$ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh`.
Compares the result against the `#omz revision:` annotation in the compdump.
If they match, writes the stamp so the next startup takes the fast path.

The function has no knowledge of any fpath contributor other than OMZ.

#### `zdot_compinit_defer` (`core/plugin-bundles/omz.zsh:224–280`)

```zsh
zdot_compinit_defer() {
    [[ -o interactive ]] || return 0
    [[ $_ZDOT_COMPINIT_DEFERRED -eq 1 ]] && return 0
    _zdot_compdef_queue_init
    zdot_init_compfile
    autoload -Uz compinit
    local compfile="$_ZDOT_COMPFILE"
    local do_compinit=1
    if [[ -f "$compfile" ]] && ! zdot_compdump_needs_refresh; then
        do_compinit=0
    fi
    if [[ $do_compinit -eq 1 ]]; then
        if [[ "$ZSH_DISABLE_COMPFIX" != true ]]; then
            autoload -Uz compaudit
            compinit -i -d "$compfile"
        else
            compinit -u -d "$compfile"
        fi
        local omz_rev cache
        cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
        omz_rev=$(cd "$cache" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
        if [[ -n "$omz_rev" ]]; then
            {
                echo
                echo "#omz revision:$omz_rev"
                echo "#omz fpath:${fpath[*]}"   # written; never read anywhere
            } >> "$compfile"
            print -n "$omz_rev" >| "${compfile}.rev" 2>/dev/null
        fi
        {
            if [[ -s "$compfile" && (! -s "${compfile}.zwc" || "$compfile" -nt "${compfile}.zwc") ]]; then
                if command mkdir "${compfile}.lock" 2>/dev/null; then
                    autoload -U zrecompile
                    zrecompile -q -p "$compfile"
                    command rm -rf "${compfile}.zwc.old" "${compfile}.lock" 2>/dev/null
                fi
            fi
        } &!
    fi
    _ZDOT_COMPINIT_DONE=1
    _ZDOT_COMPINIT_DEFERRED=1
    zdot_compdef_queue_process
    return 0
}
```

Key observations from the actual body:

- `compinit -i -d "$compfile"` writes to `$_ZDOT_COMPFILE` (not `~/.zcompdump`).
- The `#omz fpath:${fpath[*]}` annotation captures fpath **at call time** —
  the deferred plugins have not loaded yet, so their fpath contributions are
  absent.
- A search of the entire codebase (`rg '#omz fpath'`) produces exactly one
  match: this `echo` statement. The annotation is written but **never read**.
  It was previously used in a validity check that was removed because it
  invalidated the cache on every startup.

#### `zdot_compinit_reexec` (`core/plugin-bundles/omz.zsh:282–286`)

**Before Fix 1 (buggy):**

```zsh
zdot_compinit_reexec() {
    compinit -i           # missing: -d "$compfile"
    _ZDOT_COMPINIT_DONE=1
    zdot_compdef_queue_process
}
```

**After Fix 1 (current):**

```zsh
zdot_compinit_reexec() {
    local compfile="$_ZDOT_COMPFILE"

    if [[ "$ZSH_DISABLE_COMPFIX" != true ]]; then
        autoload -Uz compaudit
        compinit -i -d "$compfile"
    else
        compinit -u -d "$compfile"
    fi
    _ZDOT_COMPINIT_DONE=1
    zdot_compdef_queue_process
}
```

The pre-fix function omitted the `-d "$compfile"` flag. When called, zsh's
`compinit` defaulted to writing `~/.zcompdump` instead of `$_ZDOT_COMPFILE`.
The fix adds `-d "$compfile"` in both the compaudit and `ZSH_DISABLE_COMPFIX`
branches, ensuring re-execution always targets the correct dump file.

#### `zdot_ensure_compinit_during_precmd` (`core/plugin-bundles/omz.zsh:294–303`)

A precmd hook registered by `zdot_enable_compinit_precmd`. Runs at most once
per session (guarded by `_ZDOT_COMPINIT_CHECKED_DURING_PRECMD`). If
`_ZDOT_COMPINIT_DONE` is already set (which it is whenever
`zdot_compinit_defer` ran successfully), the hook returns early **without**
calling `zdot_compinit_reexec`. The reexec path is only reached if
`zdot_compinit_defer` was skipped (non-interactive shell, or deferred flag
already set) and `zdot_compdump_needs_refresh` returns true.

### 1.3 Problem A — fpath Gap: Confirmed Observable

#### Deferred plugins that add to fpath

`olets/zsh-abbr` (`~/.cache/zdot/plugins/olets/zsh-abbr/zsh-abbr.plugin.zsh`):

```zsh
fpath+=${0:A:h}/completions    # line 1 — the entire fpath-related content
```

That directory (`~/.cache/zdot/plugins/olets/zsh-abbr/completions/`) contains
`_abbr` (confirmed: file has `#compdef abbr` header). `zsh-abbr.plugin.zsh`
contains **no `compdef` call** — there is no fallback registration mechanism.
`_abbr` reaches the completion system only if its directory is in `fpath` at
compinit time.

`zdharma-continuum/fast-syntax-highlighting`:
```zsh
fpath+=${0:h}    # in fast-syntax-highlighting.plugin.zsh
```
This directory contains `_fast-theme`.

`olets/zsh-abbr` also sources its submodule `zsh-job-queue`, which has a
`completions/` subdirectory containing `_job-queue`. That directory is added
to `fpath` before `compinit` only if `zsh-abbr` loads before `compinit`.

#### Measured result

Inspection of `~/.zcompdump-cascade-5.9` (the active compdump, written by
`compinit -d "$compfile"`) confirms:

- `_abbr` is **not present** in the compdump.
- `_fast-theme` is **not present** in the compdump.
- `_job-queue` is **not present** in the compdump.
- None of the directories added by deferred plugins appear in the
  `#omz fpath:` annotation.

**Consequence**: `abbr<TAB>` does not complete. `_abbr` is never registered in
`_comps[]`. This is not theoretical — completion for `abbr` is actively broken
in the current configuration.

`zsh-autosuggestions` does not add to `fpath` (no `fpath+=` in its source);
it is not affected by this gap.

#### Execution trace for a cold start (compdump absent or stale)

```
_plugins_load_omz() called
  → zdot_load_plugin omz:lib       # fpath unchanged at this level
  → zdot_load_plugin omz:plugins/git
  → ...
  → zdot_compinit_defer()          # line 100
      → zdot_compdump_needs_refresh() → returns 0 (stale)
      → compinit -i -d "$compfile"
          # fpath at this point: OMZ dirs + system dirs
          # zsh-abbr/completions: NOT in fpath
          # fast-syntax-highlighting: NOT in fpath
      → echo "#omz fpath:${fpath[*]}" >> "$compfile"   # captures stale fpath
      → zdot_compdef_queue_process()
      → return
← _plugins_load_omz returns
  → hook system fires plugins-loaded
    → _plugins_load_deferred()
        → zdot_load_deferred_plugins olets/zsh-abbr
            → source zsh-abbr.plugin.zsh
                → fpath+=${0:A:h}/completions    # NOW added — too late
        → zdot_load_deferred_plugins zdharma-continuum/fast-syntax-highlighting
            → source fast-syntax-highlighting.plugin.zsh
                → fpath+=${0:h}                  # NOW added — too late
```

On warm starts (compdump fresh), compinit is skipped entirely, so the fpath
gap is not corrected on subsequent startups either. The compdump persists until
OMZ updates.

### 1.4 Problem B — Validity Signal: OMZ Revision Only

The compdump is considered fresh when the OMZ git HEAD matches the
`#omz revision:` annotation. Changes invisible to this check:

- Any deferred plugin updated (git pull in its cache dir)
- A completion directory added to or removed from `fpath` via config change
- `$ZSH_CACHE_DIR/completions` contents changed (e.g., new tool installs a
  completion there via `zdot_add_completion`)
- The `zsh-abbr`, `fzf-tab`, or `fast-syntax-highlighting` plugin dirs updated

The `#omz fpath:` annotation captures `fpath` at compinit time and would be a
suitable additional signal, but it is not currently read anywhere. Re-enabling
a fpath-based check would require careful comparison logic to avoid false
positives from ordering differences or ephemeral entries.

### 1.5 Options

#### Option A — Move compinit to a later phase

Remove the `zdot_compinit_defer` call from `_plugins_load_omz` (line 100) and
instead call it from a new hook function that runs after `fzf-tab-loaded`.

Concretely, using the actual hook API signature from `core/hooks.zsh`:

```zsh
# In lib/plugins/plugins.zsh (or a new file sourced after plugin declarations):

_plugins_run_compinit() {
    zdot_compinit_defer
}

zdot_hook_register _plugins_run_compinit interactive \
    --requires fzf-tab-loaded \
    --provides compinit-done
```

Remove line 100 from `_plugins_load_omz`. `compdef` calls queued by OMZ
plugins during `omz-plugins-loaded` are already buffered by
`_zdot_compdef_queue_init` and replayed by `zdot_compdef_queue_process` at
the end of `zdot_compinit_defer`, so those continue to work.

Any hook currently using `--requires omz-plugins-loaded` that depends on
compinit having run would need to change to `--requires compinit-done`. A
search for `omz-plugins-loaded` in hook registrations is needed to audit this.

Tradeoffs:

| | |
|---|---|
| + | compinit sees the complete fpath from all plugins — resolves the `abbr<TAB>` breakage |
| + | Eliminates the most common source of stale completions |
| + | `#omz fpath:` annotation would now capture the full fpath, making it a usable signal |
| − | First-prompt latency increases slightly (compinit moves later in the chain) |
| − | Requires auditing `--requires` chains for anything that assumes compinit has run |
| − | Adds a new phase (`compinit-done`) to the chain; more moving parts |
| − | The `zdot_compinit_reexec` bug (missing `-d "$compfile"`) is independent and still needs a fix |

---

#### Option B — Hash-based cache key

Replace the OMZ-revision check with a hash derived from fpath contents or
mtimes. The compdump is stale if the stored hash does not match the recomputed
value.

Using the actual compfile variable from `zdot_compinit_defer`:

```zsh
# Compute hash of all completion file names visible in fpath:
local fpath_hash
fpath_hash=$(print -l ${^fpath}/_(N) | md5 2>/dev/null || print -l ${^fpath}/_(N) | md5sum)
# Store alongside compdump:
print -n "$fpath_hash" >| "${compfile}.fphash"
# On next startup, in zdot_compdump_needs_refresh:
[[ -f "${compfile}.fphash" ]] && [[ "$(<${compfile}.fphash)" == "$fpath_hash" ]] && return 1
```

This requires computing the hash after all plugins have loaded (i.e., requires
Option A or an equivalent timing fix to be useful).

Tradeoffs:

| | |
|---|---|
| + | Correct across all fpath contributors regardless of source |
| + | No dependency on OMZ git history |
| − | Globbing all completion entries on every startup adds measurable cost |
| − | Only useful if compinit timing is also fixed (Option A); otherwise hashes stale fpath anyway |
| − | Sensitive to irrelevant changes (unrelated files in a completion directory) |

---

#### Option C — Mtime-based validity on known completion dirs

Stat a fixed list of known completion directories. If any is newer than the
compdump, invalidate and re-run.

Using the actual compfile variable:

```zsh
# In zdot_compdump_needs_refresh, before or after the revision check:
local _compdump_mtime _dir
zstat -A _compdump_mtime +mtime "$compfile" 2>/dev/null || return 0
local _check_dirs=(
    "$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh/plugins"
    "$_ZDOT_PLUGINS_CACHE/olets/zsh-abbr/completions"
    "$_ZDOT_PLUGINS_CACHE/zdharma-continuum/fast-syntax-highlighting"
    "$ZSH_CACHE_DIR/completions"
)
for _dir in $_check_dirs; do
    [[ -d $_dir ]] || continue
    local _dir_mtime
    zstat -A _dir_mtime +mtime "$_dir" 2>/dev/null || continue
    (( _dir_mtime > _compdump_mtime )) && return 0
done
```

`zstat` is part of `zsh/stat` (autoloaded); no subshell required.

Tradeoffs:

| | |
|---|---|
| + | Cheaper than hashing — only stat calls, no glob |
| + | Catches plugin updates (git pull updates directory mtime) |
| − | The list of dirs must be kept in sync with actual fpath contributors manually |
| − | Misses in-place file changes that do not update the parent directory mtime |
| − | Does not detect removal of a completion dir from fpath (only additions/updates) |
| − | Still needs Option A to ensure the dirs are actually in fpath when compinit runs |

---

#### Option D — Fix `zdot_compinit_reexec` independently

Regardless of which option is chosen for fpath coverage, `zdot_compinit_reexec`
has a standalone bug. The fix is one word:

```zsh
zdot_compinit_reexec() {
    compinit -i -d "$_ZDOT_COMPFILE"    # was: compinit -i
    _ZDOT_COMPINIT_DONE=1
    zdot_compdef_queue_process
}
```

`$_ZDOT_COMPFILE` is set by `zdot_init_compfile` before `zdot_compinit_defer`
runs and is not unset afterward, so it is available in `zdot_compinit_reexec`.
This fix is independent of and orthogonal to fpath timing.

Tradeoffs:

| | |
|---|---|
| + | Correct: re-execution writes to the same location as the initial run |
| + | Minimal change with no risk of phase ordering impact |
| − | The reexec path is only reached in edge cases (compdump stale after login); low frequency |

---

#### Option E — Status quo

Accept the current behavior. The compdump is keyed on the OMZ revision;
completions from deferred plugins are absent from the compdump and from
`_comps[]`. `abbr<TAB>` does not work.

The `#omz fpath:` annotation already exists in the compdump and records fpath
at compinit time. It could be activated as an additional validity signal without
moving compinit — though it would encode the stale (pre-deferred) fpath, not
the full fpath.

Tradeoffs:

| | |
|---|---|
| + | No changes required |
| + | Proven stable; no new phase ordering risks |
| − | `abbr<TAB>` completion is actively broken — this is an observed symptom, not theoretical |
| − | No signal for deferred-plugin, fzf-tab, or custom completion dir changes |
| − | `zdot_compinit_reexec` bug persists, writing to wrong location on edge-case re-runs |

---

## 2. Clone Fast Path

### 2.1 Mechanism

`zdot_plugins_clone_all` (`core/plugins.zsh:179–231`) manages the sentinel.

**Before Fixes 3 & 4 (buggy):**

```zsh
zdot_plugins_clone_all() {
    local sentinel="${_ZDOT_PLUGINS_CACHE}/.cloned"
    local current_specs="${(j: :)_ZDOT_PLUGINS_ORDER}"    # line 183 — bare spec names only

    if [[ -f "$sentinel" ]] && [[ "$(<$sentinel)" == "$current_specs" ]]; then
        # Fast path: populate _ZDOT_PLUGINS_PATH for plain user/repo specs only
        local _fast_spec
        for _fast_spec in $_ZDOT_PLUGINS_ORDER; do
            [[ $_fast_spec == *:* ]] && continue    # line 197 — skips all bundle specs
            _ZDOT_PLUGINS_PATH[$_fast_spec]="${_ZDOT_PLUGINS_CACHE}/${_fast_spec}"    # line 198
        done
        return 0
    fi

    # Slow path: clone missing plugins, then write sentinel
    local spec
    for spec in $_ZDOT_PLUGINS_ORDER; do
        zdot_plugin_clone "$spec"
    done
    print -n "$current_specs" >| "$sentinel"    # line 209
}
```

**After Fixes 3 & 4 (current):**

```zsh
zdot_plugins_clone_all() {
    local sentinel="${_ZDOT_PLUGINS_CACHE}/.cloned"

    # Build current_specs with @version suffixes where set
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

    if [[ -f "$sentinel" ]] && [[ "$(<$sentinel)" == "$current_specs" ]]; then
        # Fast path: populate _ZDOT_PLUGINS_PATH; also verify dirs exist on disk
        local _fast_spec _fast_cache _fast_all_present=1
        _fast_cache=${_ZDOT_PLUGINS_CACHE}
        for _fast_spec in $_ZDOT_PLUGINS_ORDER; do
            [[ -n "${_ZDOT_PLUGINS_PATH[$_fast_spec]}" ]] && continue
            # This is safe only because no omz:* spec uses kind=defer — if that
            # ever changes, this skip must be revisited.
            [[ $_fast_spec == *:* ]] && continue
            if [[ ! -d "${_fast_cache}/${_fast_spec}" ]]; then
                _fast_all_present=0
                break
            fi
            _ZDOT_PLUGINS_PATH[$_fast_spec]="${_fast_cache}/${_fast_spec}"
        done
        [[ $_fast_all_present -eq 1 ]] && return 0
    fi

    # Slow path: clone missing plugins, then write sentinel
    local spec
    for spec in $_ZDOT_PLUGINS_ORDER; do
        zdot_plugin_clone "$spec"
    done
    print -n "$current_specs" >| "$sentinel"
}
```

Fix 3 rewrites the sentinel-building loop to consult `_ZDOT_PLUGINS_VERSION`
and encode `@version` suffixes into `current_specs`, so version-pin changes
invalidate the sentinel. Fix 4 adds a directory-existence check inside the
fast path so that a missing plugin directory (e.g. after manual cache deletion)
forces the slow path rather than silently populating a stale path map.

`zdot_use` strips `@version` before storing in `_ZDOT_PLUGINS_ORDER`
(`core/plugins.zsh:95–98`):

```zsh
zdot_use() {
    local spec="${1%%@*}"       # strips @version suffix
    local version="${1#*@}"
    version="${version:#$spec}" # empty if no @ was present
    _ZDOT_PLUGINS_ORDER+=($spec)
    _ZDOT_PLUGINS_VERSION[$spec]="$version"
    ...
}
```

The sentinel is built from `_ZDOT_PLUGINS_ORDER` (line 183), which holds only
bare specs. `_ZDOT_PLUGINS_VERSION` is never consulted during fast-path
validation.

### 2.2 Confirmed Gaps

#### Gap 1 — Version pins not encoded in sentinel

**Execution trace for a version-pin change:**

```
Config: zdot_use olets/zsh-abbr@v5.7.0
→ _ZDOT_PLUGINS_ORDER += "olets/zsh-abbr"
→ _ZDOT_PLUGINS_VERSION[olets/zsh-abbr] = "v5.7.0"

Sentinel at ~/.cache/zdot/plugins/.cloned: "... olets/zsh-abbr ..."

Next startup: config changed to zdot_use olets/zsh-abbr@v5.8.0
→ _ZDOT_PLUGINS_ORDER += "olets/zsh-abbr"     # identical
→ current_specs = "... olets/zsh-abbr ..."   # identical to sentinel
→ fast path fires → zdot_plugin_clone never called
→ v5.7.0 checkout remains on disk, silently
```

The version change is silently dropped until the sentinel is manually deleted
(`rm ~/.cache/zdot/plugins/.cloned`) or the spec list changes for another
reason.

#### Gap 2 — No disk-presence check

The fast path matches sentinel text against current spec text only. It does
not verify that `$_ZDOT_PLUGINS_CACHE/$spec` exists on disk.

**Execution trace for a manual deletion:**

```
rm -rf ~/.cache/zdot/plugins/olets/zsh-abbr

Next startup:
→ sentinel matches current_specs → fast path fires
→ _ZDOT_PLUGINS_PATH[olets/zsh-abbr] = "~/.cache/zdot/plugins/olets/zsh-abbr"
   (path set to nonexistent dir — no error)
→ zdot_load_deferred_plugins olets/zsh-abbr:
    → plugin_path="${_ZDOT_PLUGINS_PATH[olets/zsh-abbr]}"
    → glob: $plugin_path/*.plugin.zsh(N) → empty
    → plugin not loaded, no error message
```

The failure is silent. No diagnostic is emitted.

#### Gap 3 — `omz:*` paths not populated on fast path

Line 197 skips all `*:*` specs during fast-path path population. For `omz:*`
specs, `_ZDOT_PLUGINS_PATH[omz:*]` is never set on the fast path.

This is currently safe because every `omz:*` spec in `lib/plugins/plugins.zsh`
is declared **without** `kind=defer`. They are loaded by `zdot_load_plugin`
directly inside `_plugins_load_omz`, which resolves paths through the `omz`
bundle handler rather than looking up `_ZDOT_PLUGINS_PATH`.

The coupling is invisible: if a future change declared an `omz:*` spec as
`kind=defer`, `zdot_load_deferred_plugins` would look up `_ZDOT_PLUGINS_PATH`,
find it empty on the fast path, and silently skip the plugin.

### 2.3 Slow-Path Subshells

`zdot_plugin_clone` (line 146) calls `_zdot_bundle_handler_for` in a `$()`
subshell (line 152) for every spec during the slow path. This subshell is only
hit when the sentinel is absent or stale — first run after adding or removing
a plugin, or after a manual cache wipe. It is not on the normal startup hot
path.

`zdot_load_plugin` (line 218) also calls `_zdot_bundle_handler_for` in a
subshell (line 232) and has two additional subshells for plain `user/repo`
specs with no registered handler (lines 238 and 244: `plugin_path=$(...)` and
`plugin_file=$(ls ... | head -1)`). These lines are not currently reached in
normal startup — all plain `user/repo` specs are `kind=defer` and handled by
`zdot_load_deferred_plugins` (which was already fixed). These are latent
subshells.

### 2.4 Options

#### Option A — Include version in sentinel content

Build the sentinel from spec/version pairs rather than bare spec names.
Using the actual data structures from `core/plugins.zsh`:

```zsh
# In zdot_plugins_clone_all, replace lines 183 and 209:
local _spec _sv_parts=()
for _spec in $_ZDOT_PLUGINS_ORDER; do
    _sv_parts+=("${_spec}@${_ZDOT_PLUGINS_VERSION[$_spec]:-}")
done
local current_specs="${(j: :)_sv_parts}"
```

The sentinel write at line 209 uses the same `current_specs` variable and
requires no separate change.

Tradeoffs:

| | |
|---|---|
| + | Version pin changes trigger a re-clone automatically |
| + | Minimal structural change — only sentinel content format changes |
| − | Existing sentinels become stale on first run after the change (one extra slow-path startup) |
| − | Does not address the disk-presence gap (Gap 2) |

---

#### Option B — Full disk-presence check on fast path

After the sentinel text matches, verify that each `user/repo` plugin directory
exists:

```zsh
# After the sentinel match, before returning:
local _fast_spec
for _fast_spec in $_ZDOT_PLUGINS_ORDER; do
    [[ $_fast_spec == *:* ]] && continue
    local _expected="${_ZDOT_PLUGINS_CACHE}/${_fast_spec}"
    if [[ ! -d "$_expected" ]]; then
        # Directory missing — fall through to slow path
        break
    fi
    _ZDOT_PLUGINS_PATH[$_fast_spec]="$_expected"
done
# If loop completed without break, return 0 (all dirs present)
# Otherwise fall through to slow path below
```

This requires restructuring the fast path to use a `break`-and-fallthrough
pattern rather than an early `return 0`.

Tradeoffs:

| | |
|---|---|
| + | Catches manual deletions and corrupted caches |
| + | Consistent with what `zdot_plugin_clone` already does (checks dir existence) |
| − | Adds `[[ -d ]]` tests for every `user/repo` spec on every startup |
| − | For large spec lists, this cost becomes comparable to the slow path |

---

#### Option C — Probabilistic disk-presence check

Check only a sample of plugin directories (e.g., the first three). If any is
missing, fall through to the slow path.

```zsh
local _sample _sentinel_ok=1
for _sample in ${_ZDOT_PLUGINS_ORDER[1,3]}; do
    [[ $_sample == *:* ]] && continue
    [[ -d "${_ZDOT_PLUGINS_CACHE}/${_sample}" ]] || { _sentinel_ok=0; break }
done
(( _sentinel_ok )) || # fall through to slow path
```

Tradeoffs:

| | |
|---|---|
| + | Very cheap: at most three `[[ -d ]]` tests |
| + | Catches the common case (cache wipe removes all dirs) |
| − | A targeted deletion of a non-sampled dir goes undetected |
| − | The "probabilistic" nature means correctness is not guaranteed |

---

#### Option D — Populate `omz:*` paths on fast path

Remove the invisible coupling between the fast-path skip and the assumption
that no `omz:*` spec uses `kind=defer`. The fix is to call the `omz` bundle
handler's path resolver for `omz:*` specs on the fast path instead of
skipping them.

The `omz` bundle handler path resolution is performed by
`zdot_bundle_omz_clone` (in `core/plugin-bundles/omz.zsh`). On a warm startup
where the OMZ cache dir already exists, `zdot_bundle_omz_clone` is
effectively a no-op that sets `_ZDOT_PLUGINS_PATH[spec]` and returns. An
alternative is to compute the path inline:

```zsh
# Replace the *:* continue guard (line 197) with:
if [[ $_fast_spec == omz:* ]]; then
    local _omz_sub="${_fast_spec#omz:}"
    _ZDOT_PLUGINS_PATH[$_fast_spec]="${_ZDOT_PLUGINS_CACHE}/ohmyzsh/ohmyzsh/${_omz_sub}"
elif [[ $_fast_spec == *:* ]]; then
    continue    # other bundle types still skipped
else
    _ZDOT_PLUGINS_PATH[$_fast_spec]="${_ZDOT_PLUGINS_CACHE}/${_fast_spec}"
fi
```

This assumes the OMZ cache path layout is stable, which it is (set by
`core/plugin-bundles/omz.zsh`).

Tradeoffs:

| | |
|---|---|
| + | Removes the invisible coupling assumption |
| + | Correct even if an `omz:*` spec is declared `kind=defer` in future |
| − | Encodes the OMZ path layout in a second location (duplicates logic from the handler) |
| − | Low urgency: no current spec hits the broken case |

---

#### Option E — Fix `zdot_load_plugin` latent subshells (lines 238, 244)

The subshells at lines 238 and 244 in `zdot_load_plugin` are structurally
identical to those eliminated in `zdot_load_deferred_plugins` during the
performance refactor. They are currently unreachable in normal startup but
would be hit if a plain `user/repo` spec were ever loaded via `zdot_load_plugin`
directly (e.g., a non-deferred, non-bundle spec added in future).

The pattern to eliminate them is the same as the deferred-plugins fix:
pre-populate `_ZDOT_PLUGINS_PATH` before reaching line 238, then replace the
`$(...)` subshells with direct variable lookups.

Tradeoffs:

| | |
|---|---|
| + | Consistent with the existing fix in `zdot_load_deferred_plugins` |
| + | Removes latent risk if the call pattern changes |
| − | Currently unreachable — no observed impact |
| − | Requires the same `_ZDOT_PLUGINS_PATH` pre-population pattern as the existing fix |

---

## Summary of Open Questions

### Compdump

1. **fpath timing (answered)**: The fpath gap is observable, not theoretical.
   `abbr<TAB>` completion is actively broken. `_abbr`, `_job-queue`, and
   `_fast-theme` are confirmed absent from `~/.zcompdump-cascade-5.9`.

2. **`zdot_compinit_reexec` bug (answered)**: The missing `-d "$compfile"` flag
   causes re-execution to write to `~/.zcompdump` instead of `$_ZDOT_COMPFILE`.
   Fix is independent of fpath timing.

3. **Cost of moving compinit later (Option A)**: The increase in first-prompt
   latency from moving compinit after `fzf-tab-loaded` has not been measured.
   On warm starts (compdump fresh), compinit is skipped and the timing change
   has no effect. On cold starts, the cost is the time for deferred plugins to
   source their files before compinit runs.

4. **`#omz fpath:` annotation reuse**: The annotation captures stale fpath
   (pre-deferred). Re-enabling it as a validity signal without fixing timing
   would detect fpath changes from config edits but not from deferred plugins.

### Clone Fast Path

1. **Version pin silencing (answered)**: Changing a `@version` pin produces an
   identical sentinel — the re-clone is silently skipped. This is a confirmed
   behavior, not an edge case.

2. **`omz:*` coupling (answered)**: The fast-path skip for `*:*` specs is
   safe only as long as no `omz:*` spec uses `kind=defer`. This is an implicit
   constraint with no enforcement mechanism.

3. **Latent subshells in `zdot_load_plugin`**: Not reached in normal startup.
   The decision to fix them now vs. when they become observable is a matter of
   maintenance preference.
