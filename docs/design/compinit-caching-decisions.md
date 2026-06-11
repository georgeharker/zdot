# Decision Record: Compinit Staleness & Cache Invalidation

> Distilled from the retired `omz-integration-analysis.md`,
> `cache-invalidation-refactor.md`, and `fix-validation-report.md` (full text
> in git history). Corrected against `core/compinit.zsh`, `core/cache.zsh`,
> and `core/plugins.zsh` on 2026-06-10 — an earlier draft of this record
> misstated the metadata outcome. The present-tense design is
> [compdump-and-clone-fastpath.md](compdump-and-clone-fastpath.md).

## Where this started

Compdump staleness detection originally lived inside the OMZ bundle and
consisted of one signal: an `#omz revision:` annotation grepped out of the
dump, compared against the OMZ repo's HEAD. The investigation (kept as the
design doc above) fixed four correctness bugs around it, but the follow-on
analysis showed the deeper problem was structural — the check knew about
exactly one fpath contributor. A third-party plugin shipping a new
completion, a directory joining `$fpath`, or a pinned plugin updating in
place all left the dump stale with no signal at all.

The refactor proposal on the table had four changes: (1) adopt use-omz's
"F2" external-metadata pattern for staleness, (2) make the precmd safety
net run compinit unconditionally, (3) detect plugin revision changes
generically, and (4) wire that detection into the plan cache.

## What shipped, and how it differs from the proposal

**The metadata pattern was adopted — but generalized into core, not kept as
OMZ machinery.** The proposal phrased Change 1 as extracting
`zdot_omz_compdump_*` functions; what exists instead is bundle-agnostic:
`core/compinit.zsh` keeps `$XDG_CACHE_HOME/zdot/zcompdump-metadata.zsh`, a
`typeset -p` serialization of a bundle-revision stamp, the full `$fpath`,
and the sorted `_*` file list, compared on every staleness check
(`_zdot_compdump_needs_refresh`, written back by
`zdot_compdump_write_meta` after each full compinit). Bundles contribute
through one hook — `_zdot_compdump_bundle_stamp`, which OMZ overrides with
its repo HEAD — rather than owning the mechanism. The earlier OMZ-only
revision grep is gone, and with it the "fpath changes are invisible"
problem: fpath composition and contents are first-class staleness inputs
now.

**The precmd change became moot instead of being made.** The bug the
proposal targeted: the precmd safety net gated on the staleness check, so
when the deferred trigger failed to fire *and* the compdump was fresh,
compinit was silently never run — completions dead, no error anywhere. A
canonical invisible failure: a guard correct in the happy path, wrong when
its assumptions broke. Rather than patching the guard, the relay it
belonged to (defer → flag → precmd) was deleted outright:
`zdot_compinit_run` executes directly in the deferred drain (the historical
hang it was avoiding does not reproduce on current zsh), and the safety net
became the `finally`-group fallback — it fires exactly once after the drain
rather than re-checking per prompt, and a genuinely stalled config still
surfaces as a stall instead of being silently patched.

**Changes 3–4 shipped as proposed.** `zdot_plugins_have_changed`
(`core/plugins.zsh`) compares every git-backed plugin's HEAD against the
`plugin-revs.zsh` stamp; `load_cache` (`core/cache.zsh`) runs it on
plan-cache load and raises `_ZDOT_FORCE_COMPDUMP_REFRESH`, which the
staleness check honors unconditionally. This is the signal the metadata
can't produce: changed plugin *content* behind an identical file list.
`zdot cache invalidate` clears both the metadata and the rev stamp.

## Residue

The analysis-era `#omz fpath:` sentinel annotation — written but read by
nothing — is gone entirely: the metadata file carries the fpath signal
properly, and the dead annotation was removed with it. No residue remains
from this lineage.

## Verification history

The four investigation fixes were validated point-in-time on 2026-02-18
(retired report) and re-validated against `core/` on 2026-06-10, alongside
the corrections recorded here.
