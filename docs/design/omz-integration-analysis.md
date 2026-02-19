# OMZ Integration Analysis

**Date:** 2026-02-19  
**Status:** Analysis only — no implementation changes proposed here  
**Baseline:** All four fixes confirmed applied (see `fix-validation-report.md`)

---

## 1. Executive Summary

The OMZ integration in `core/plugin-bundles/omz.zsh` is **correct for the common case**. All four
fixes from the design phase are applied and verified. The compinit timing issue (Fix 2) is genuinely
resolved — fpath is fully populated before compinit runs.

Two gaps remain relative to the `use-omz.zsh` reference implementation:

1. **Fpath invalidation**: the `#omz fpath:` annotation is written to the compdump but never read
   back. Compdump expiry is checked against OMZ git rev only.
2. **Precmd safety-net logic**: the hook silently skips compinit if the compdump is fresh but
   `zsh-defer` never fired — leaving completions broken in that edge case.

A third difference (compdef serialization) is theoretically less robust than the reference but
carries negligible practical risk.

---

## 2. Fix 2 Verification: Compinit Ordering

**Claim:** compinit is enqueued after all deferred plugin `fpath` additions, so every plugin's
completion directory is visible when compinit runs.

**Evidence:**

`core/plugins.zsh:332–361` — `zdot_load_deferred_plugins`:

```zsh
# For each deferred plugin: zdot_defer source "$plugin_file"
# Then, after the loop:
zdot_defer zdot_compinit_defer   # L361 — enqueued last
```

`lib/plugins/plugins.zsh:84–100` — `_plugins_load_omz` does **not** call `zdot_compinit_defer`
directly. It only sets up OMZ environment variables and calls `zdot_load_omz_bundle`. Compinit
deferral is handled entirely by `zdot_load_deferred_plugins`.

`zsh-defer` processes its queue FIFO inside a single `zle-line-init` hook (a while-loop that drains
the queue). This means every `zdot_defer source "$plugin_file"` call — including any `fpath`
additions those plugins perform — completes before `zdot_compinit_defer` is invoked.

**Conclusion:** Fix 2 is genuine. The timing gap is closed.

---

## 3. Remaining Gap: Fpath Invalidation

### What we write

`zdot_compinit_defer` (L258) and `zdot_compinit_reexec` (L300) both append to the compdump:

```zsh
echo "#omz fpath:${fpath[*]}"
```

### What we read

`zdot_compdump_needs_refresh` (L170–215) reads only:

```zsh
old_rev=$(grep -m1 -F '#omz revision:' "$compfile" ... | cut -d: -f2-)
```

The `#omz fpath:` line is **never read**. The compdump is considered fresh as long as the OMZ git
rev has not changed.

### Consequence

If the set of active plugins changes (adding/removing a plugin that contributes completion
functions) but the OMZ git rev stays the same, the compdump is not expired. The stale compdump
will be used until either:

- the OMZ repo is updated (rev changes), or
- the compdump ages past `zdot_has_zcompdump_expired`'s threshold (24 h by default), or
- the user manually deletes the compdump.

### How the reference handles it

`use-omz.zsh` stores both revision and fpath in an external metadata file
(`$ZSH_CACHE_DIR/zcompdump-metadata.zsh`) using `typeset -p` serialization:

```zsh
# Written on each compinit run:
typeset -p ZSH_COMPDUMP_REV ZSH_COMPDUMP_FPATH >| "$ZSH_CACHE_DIR/zcompdump-metadata.zsh"

# Checked on each startup:
source "$ZSH_CACHE_DIR/zcompdump-metadata.zsh"
[[ "$current_rev" == "$ZSH_COMPDUMP_REV" && "${fpath[*]}" == "$ZSH_COMPDUMP_FPATH" ]] || ...
```

The metadata file survives compdump regeneration, requires no `grep`, and natively handles fpath
comparison.

### Practical severity

Low-to-medium. The fpath changes that matter are plugin additions/removals, which are deliberate
user actions. In practice, most users restart their shell or wait 24 hours after such changes,
which triggers a rebuild anyway. However, a user who adds a new plugin and opens a new terminal
tab without waiting 24 hours may get stale completions with no obvious explanation.

---

## 4. Remaining Gap: Precmd Safety-Net Logic

### Current behaviour (`zdot_ensure_compinit_during_precmd`, L325–333)

```zsh
zdot_ensure_compinit_during_precmd() {
    [[ $_ZDOT_COMPINIT_CHECKED_DURING_PRECMD -eq 1 ]] && return 0
    [[ -n "$_ZDOT_COMPINIT_DONE" ]] && return 0

    _ZDOT_COMPINIT_CHECKED_DURING_PRECMD=1

    if zdot_compdump_needs_refresh; then
        zdot_compinit_reexec
    fi
}
```

### The gap

The precmd hook is a fallback for when `zsh-defer` never fires (e.g. the `zle-line-init` hook is
overridden or `zsh-defer` is not loaded). In that scenario:

- `_ZDOT_COMPINIT_DONE` is unset (compinit hasn't run).
- `zdot_compdump_needs_refresh` returns `1` (no refresh needed — compdump is fresh).
- The hook exits without calling compinit.
- **Completions are silently broken.**

The guard `if zdot_compdump_needs_refresh` is intended to avoid a redundant compinit call, but it
inadvertently makes compinit conditional in a situation where it is unconditionally required.

### How the reference handles it

`use-omz.zsh`'s `ensure-compinit-during-precmd` calls `run-compinit` unconditionally if
`compinit_deferred` is still defined (i.e. compinit hasn't run). The function also removes itself
from `precmd_functions` after the first run.

```zsh
ensure-compinit-during-precmd() {
    if (( ${+functions[compinit_deferred]} )); then
        run-compinit
    fi
    add-zsh-hook -d precmd ensure-compinit-during-precmd
}
```

This is simpler and correct: if compinit hasn't run, run it unconditionally.

### Practical severity

Low. The `zsh-defer` + `zle-line-init` path is reliable in practice. The safety net would only
matter if `zsh-defer` fails to initialise or is bypassed (non-standard configurations). However,
when it does fail, the failure is invisible — no error, just missing completions.

---

## 5. Compdef Queue: Serialization Comparison

### Our implementation (L103–136)

```zsh
_compdef_queue() {
    _ZDOT_COMPDEF_QUEUE+=("$*")   # raw joined string
}

# Replay:
for cmd in "$_ZDOT_COMPDEF_QUEUE[@]"; do
    compdef "${(z)cmd}"           # (z) word-splitting
done
```

`"$*"` joins all arguments with the first character of `$IFS` (space). The `(z)` flag on replay
splits on shell-word boundaries, handling quoted strings correctly for typical `compdef` argument
patterns.

### Reference implementation (`use-omz.zsh`)

```zsh
queued_compcmd() {
    local -a args=("$@")
    local args_str="$(typeset -p args)"
    _ZDOT_COMPDEF_QUEUE+=("${args_str}; $0 \$args")
}

# Replay:
for cmpcmd in "$_ZDOT_COMPDEF_QUEUE[@]"; do
    eval $cmpcmd
done
```

`typeset -p` produces a syntactically-valid zsh assignment (quoting all special characters). Replay
via `eval` is therefore guaranteed to reconstruct the original argument array exactly.

### Assessment

The `(z)` flag handles all standard `compdef` call patterns correctly. A theoretical failure case
would be a completion function name containing embedded spaces — vanishingly rare in practice. The
risk is negligible for a typical zsh dotfiles setup.

---

## 6. Options A–E from the Design Doc: Current Status

The design doc (`compdump-and-clone-fastpath.md`) defined five options for addressing the
fpath-timing gap. Fix 2 resolved the timing issue. Here is the updated status of each:

| Option | Description | Status after Fix 2 |
|--------|-------------|-------------------|
| A | Snapshot fpath at load time; pass to compinit stub | **Moot** — timing is fixed; fpath is already correct when compinit runs |
| B | Defer all plugin loading, then compinit last | **Applied** — this is exactly Fix 2 |
| C | Run compinit synchronously at end of `.zshrc` | **Moot** — deferred approach works; synchronous is a regression for startup time |
| D | Accept stale compdump; manual rebuild workflow | **Partially applicable** — stale rev detection works; stale fpath detection is missing |
| E | Store fpath snapshot in metadata file (use-omz approach) | **Still actionable** — addresses the remaining fpath invalidation gap |

---

## 7. Design Doc Accuracy

`docs/design/compdump-and-clone-fastpath.md` contains stale code listings:

- **§1.2** ("Current compinit flow"): quotes pre-fix `zdot_compinit_defer` without `-d "$compfile"`
  argument — this was Fix 1.
- **§2.1** ("Proposed: deferred plugin loading"): shows an earlier version of `zdot_compinit_defer`
  before Fix 2's ordering change.

The **status table** and **narrative sections** in that document are accurate. Only the inline code
blocks are stale.

`docs/design/fix-validation-report.md` is accurate and up to date.

---

## 8. Recommendations for Decision

These are options for your consideration. No changes are proposed without your approval.

### Gap 1: Fpath invalidation

**Option F1 — Read back the fpath annotation (minimal change)**  
Add fpath comparison to `zdot_compdump_needs_refresh`: read the `#omz fpath:` line from the
compdump and compare against the current `${fpath[*]}`. No new files required. Keeps the existing
comment-in-compdump approach consistent.

Risk: grep on every warm startup (though one extra `grep` against a small file is negligible).

**Option F2 — External metadata file (use-omz pattern)**  
Store rev and fpath in `${ZDOTDIR}/.zcompdump.meta` using `typeset -p`. Source it on startup for
comparison. Cleaner separation; matches the reference implementation.

Risk: one extra file to manage; slightly more complex.

**Option F3 — Do nothing**  
The 24-hour age fallback (`zdot_has_zcompdump_expired`) already catches most stale-fpath cases.
Accept the edge case where a new plugin's completions take up to 24 hours to appear after adding
the plugin.

Risk: silent stale completions in a minority of cases; low practical impact.

---

### Gap 2: Precmd safety net

**Option P1 — Unconditional compinit in precmd hook**  
Change the guard to: if `_ZDOT_COMPINIT_DONE` is unset, call `zdot_compinit_defer` (not
`zdot_compinit_reexec`) unconditionally. Remove the hook from `precmd_functions` after it runs
(matching the reference pattern).

**Option P2 — Accept the current behaviour**  
The `zsh-defer` failure scenario is not observed in practice. The hook's current behaviour
(compinit only if stale) is a reasonable heuristic for avoiding double-compinit overhead.

---

### Compdef serialization

No action recommended. The `(z)` flag is sufficient for all realistic usage. Switching to
`typeset -p`/`eval` would make the code harder to read without meaningful practical benefit.
