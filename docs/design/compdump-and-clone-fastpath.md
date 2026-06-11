# Design: Compdump Lifecycle and Clone Fast Path

> Validated against `core/` on 2026-06-10. The original investigation
> transcript this replaces is in git history; the decision narrative is in
> [compinit-caching-decisions.md](compinit-caching-decisions.md).

Two subsystems that exist for the same reason — making the common-case
startup (nothing changed) cost almost nothing, without letting "nothing
changed" be assumed when it isn't true.

---

## Compdump lifecycle

### Who runs compinit, and when

`zdot_compinit_run` (`core/compinit.zsh`) is the single entry point, and it
is idempotent (`_ZDOT_COMPINIT_DONE`). Two callers exist:

- **Primary** — the completions module's `_completions_compinit`, a deferred
  hook gated `--requires-group completions`, so it fires during the deferred
  drain only after every completion producer has run and `$fpath` is
  complete. This is what makes completion live at the first prompt.
- **Floor** — `_zdot_compinit_fallback`, registered in core into the
  `finally` group. It guarantees compinit runs in a config that never loads
  the completions module.

**Why a floor in `finally` and not a precmd safety net:** `finally` means
"the deferred drain has drained" — it fires exactly once, after every
producer, still within first-prompt idle. It deliberately does *not* fire
when a hook genuinely stalls, so a real misconfiguration surfaces as a stall
error instead of being papered over every prompt. And living in core means
compinit depends on no module.

**Why it runs directly in the deferred (zsh-defer/ZLE) context:** the
historical concern that compinit hangs there does not reproduce on current
zsh (verified); running it in place keeps the whole lifecycle in one
function instead of a flag-plus-precmd relay.

### The compdef stub queue

A `compdef()` stub is installed at source time. Plugins that call `compdef`
before compinit has run get queued into `_ZDOT_COMPDEF_QUEUE` (no-op in
non-interactive shells). `zdot_compinit_run` then:

1. `unfunction compdef` — **before** compinit. If the stub still exists,
   compinit silently declines to define the real `compdef` (a function by
   that name already exists), leaving only a queue that can never drain.
2. Runs compinit (fast or full path, below).
3. Replays the queue via `zdot_compdef_queue_process`.

### Staleness: when a full compinit is required

The dump lives at `~/.zcompdump-${SHORT_HOST}-${ZSH_VERSION}`
(`_zdot_compdump_path`); every compinit invocation passes `-d` explicitly so
nothing ever writes the bare default path. `_zdot_compdump_needs_refresh`
demands a full run when any of:

1. **The dump is missing.**
2. **`_ZDOT_FORCE_COMPDUMP_REFRESH` is set** — wired from the plan-cache
   load: `load_cache` (`core/cache.zsh`) calls `zdot_plugins_have_changed`,
   which compares every git-backed plugin's HEAD against the
   `plugin-revs.zsh` stamp (`_ZDOT_PLUGINS_SAVED_REV`, `typeset -p`
   serialized).
3. **Compdump metadata mismatch.** The metadata file
   (`$XDG_CACHE_HOME/zdot/zcompdump-metadata.zsh`) is a `typeset -p` dump of
   three values captured after the last full compinit, compared against the
   current shell:
   - `ZSH_COMPDUMP_STAMP` — a bundle-revision string from the
     `_zdot_compdump_bundle_stamp` hook (empty by default; the OMZ bundle
     overrides it with its repo HEAD);
   - `ZSH_COMPDUMP_FPATH` — the full `$fpath`;
   - `ZSH_COMPDUMP_FPATH_FILES` — the sorted list of `_*` files across
     `$fpath`.

**Why three metadata signals plus a flag:** each catches a change the others
miss. The fpath comparison catches composition changes (a directory added or
removed); the fpath-files list catches a completion function appearing or
vanishing inside unchanged directories; the bundle stamp catches the OMZ
repo moving (new completions inside the same files); and the per-plugin rev
flag catches any *other* plugin updating in place — changed function content
with an identical file list. The metadata is read by `source` and written by
`typeset -p` — the serialization format is zsh itself.

### Fast and full paths

- **Fast path**: dump present and fresh → `compinit -C` — loads the cached
  dump and defines the real `compdef` without rescanning `$fpath`. No
  compaudit (the audit only ever ran at dump generation).
- **Full path**: `compinit -i` (or `-u` when compaudit is skipped — priority
  chain `zstyle ':zdot:compinit' skip-compaudit` →
  `ZDOT_SKIP_COMPAUDIT` → deprecated `ZSH_DISABLE_COMPFIX`; see
  [compinit.md](../compinit.md)). Afterwards `zdot_compinit_post_full`
  rewrites the metadata file and kicks `zdot_compdump_recompile` — a
  backgrounded (`&!`) `zrecompile` of the dump guarded by a `mkdir` lock so
  concurrent shells don't race.

`zdot cache invalidate` clears the metadata file and the plugin-rev stamp,
so the next start takes the full path by construction.

---

## Clone fast path

`zdot_plugins_clone_all` (`core/plugins.zsh`) runs on every `zdot_init`, so
its common case must not touch git or spawn subshells.

### The sentinel

The cache holds a sentinel file (`$plugins_cache/.cloned`) containing one
canonical string: every declared spec in order, each with its version pin
appended (`user/repo@v1.2.3`) when one exists. The fast path requires:

1. the current spec+pin string equals the sentinel **exactly**, and
2. every expected non-bundle plugin directory exists on disk.

When both hold, `_ZDOT_PLUGINS_PATH` is populated arithmetically (no
subshells) and the function returns without invoking git.

**Why pins are encoded in the sentinel:** a pin edit
(`user/repo@v1 → @v2`) changes which checkout is correct while leaving the
spec *list* identical — the sentinel string must change or the edit is
silently ignored.

**Why the directory check:** a manually deleted plugin directory must drop
to the slow path and re-clone, rather than recording a path to nothing.

**A documented coupling:** bundle specs (`omz:*`) are skipped in the
presence check because their handler owns their on-disk layout. This is safe
only while no `omz:*` spec uses `kind=defer` — the skip must be revisited if
that changes (noted in the code at the skip site).

### The slow path

On any mismatch, the *previous* sentinel is parsed into
`_ZDOT_PLUGINS_PREV_VERSION` — a per-spec map of the last-applied pin — so
`zdot_plugin_clone` can distinguish "the user edited this spec's pin"
(act: checkout/fetch) from "this spec is merely present in a changed list"
(act: nothing). Every spec is then offered to `zdot_plugin_clone`, and on
success the sentinel is rewritten so the next start is fast again.

The sentinel is a local optimisation artefact: it lives in the cache
directory and is never version-controlled.

---

## How this shape was arrived at

Compinit originally ran inside the OMZ bundle, eagerly at OMZ plugin-load
time. Deferred plugins — zsh-abbr, autosuggestions,
fast-syntax-highlighting — add their `$fpath` contributions after that
point, so their completions (`abbr<TAB>`) were dead until a manual
`compinit`. Moving the launch behind the `completions` group inside the
deferred drain is what fixed that, and the `finally` floor exists so the fix
doesn't depend on any particular module being loaded.

The dump path is passed explicitly everywhere because one re-exec path once
let `compinit` default it: that wrote `~/.zcompdump` while everything else
used the per-host/per-version path, leaving two dumps with one perpetually
stale.

Staleness detection grew from a single `#omz revision:` annotation grepped
out of the dump itself. That knew about exactly one fpath contributor —
OMZ — so a third-party plugin shipping a new completion never triggered a
refresh. The metadata file generalizes the idea (any bundle can stamp, and
fpath composition and contents are tracked directly), and the per-plugin
rev flag covers the remaining blind spot: content changes behind an
unchanged file list.

The clone sentinel originally recorded bare specs, which made version-pin
edits invisible — `user/repo@v1 → @v2` produced an identical sentinel and
no re-clone. Encoding pins, keeping the previous-pin map, and verifying
directories before trusting the fast path are all responses to ways the
"nothing changed" assumption proved false in practice.
