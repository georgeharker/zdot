# Docs Restructure Content Map

Review artifact for the 2026-06 documentation restructure. Every section of
the pre-restructure docs is listed with where its content now lives, or an
explicit drop reason. Validate with `scripts/check-docs.zsh` (it resolves
every `file#anchor` in the **Destination** column). Delete this file once the
restructure is reviewed.

Destination paths are relative to `docs/`. `dropped:` rows are intentional
deletions, with the reason.

## README.md (old)

| Old section | Destination |
|---|---|
| Why zdot? | `../README.md#why-zdot` |
| Quick Start / Option A: Standalone | `../README.md#option-a-standalone` (module list fixed: `shell` did not exist) |
| Quick Start / Option B: With dotfiler (steps 1–7) | `quickstart-dotfiler.md#step-1--create-your-dotfiles-repo` (was duplicated verbatim; quickstart copy is now the only one) |
| Option B / What you end up with | `quickstart-dotfiler.md#what-you-end-up-with` |
| Option B / Bootstrap on a new machine | `quickstart-dotfiler.md#bootstrap-on-a-new-machine` |
| Option B / Enable self-updates | `quickstart-dotfiler.md#step-7--enable-zdot-self-updates-optional` |
| (new) Why dotfiler is recommended | `../README.md#option-b-with-dotfiler-recommended` `quickstart-dotfiler.md#why-this-setup` |
| A Realistic `.zshrc` | `../README.md#a-realistic-zshrc` (`shell` → `history`) |
| Directory Structure | `../README.md#directory-structure` |
| Modules / Built-in Modules | `../README.md#modules` (condensed; `shell` row removed) + `modules.md#module-reference` |
| Modules / Module Search Path | `../README.md#modules` (summary) — canonical: `module-guide.md#module-search-path` |
| Modules / Writing Modules | `../README.md#modules` (teaser) — canonical: `module-guide.md#quick-start` |
| Contexts and Variants / Shell contexts | `../README.md#contexts-and-variants` (overview) — full text: `advanced.md#shell-contexts` |
| Shell contexts / Why this matters | `advanced.md#why-this-matters` |
| One file, two contexts: using `.zshrc` as `.zshenv` | `advanced.md#one-file-two-contexts-using-zshrc-as-zshenv` |
| The ordering problem: `.zshenv` runs before `/etc/zprofile` | `advanced.md#the-ordering-problem-zshenv-runs-before-etczprofile` |
| Recommended pattern: defer interactive init to `.zshrc` | `advanced.md#recommended-pattern-defer-interactive-init-to-zshrc` |
| Putting it together | `advanced.md#putting-it-together` |
| Variants | `advanced.md#variants` |
| CLI | `../README.md#cli` (verbs corrected: `cache stats` → `cache status`, added `hook plan`, `update check-updates`) — canonical: `commands.md#quick-reference` |
| Debugging | `../README.md#debugging` |
| Day-to-Day | `../README.md#day-to-day` |
| Further Reading | `../README.md#documentation` + `README.md#1-get-set-up` (docs index) |
| Acknowledgements | `../README.md#acknowledgements` |

## docs/plugins.md (deleted)

| Old section | Destination |
|---|---|
| Overview (three phases) | `using-plugins.md#the-plugin-lifecycle` |
| Usage / Declaring Plugins | `using-plugins.md#declaring-plugins` |
| Plugin Kinds | `using-plugins.md#declaring-plugins` (canonical subcommand syntax: `hook` / `defer` / `defer-prompt`; legacy forms noted) |
| OMZ Plugins | `using-plugins.md#oh-my-zsh-plugins` |
| OMZ Libraries | `using-plugins.md#oh-my-zsh-plugins` |
| Prezto Modules | `using-plugins.md#prezto-modules` (now states pz is off by default, matching the code) |
| Plugin Management Commands | `using-plugins.md#keeping-plugins-updated` — dropped: `zdot-update` / `zdot-clean` aliases (do not exist in the code) |
| Configuration / Cache Directory | `using-plugins.md#cache-locations` |
| Configuration / OMZ Theme (`ZSH_THEME`) | `using-plugins.md#oh-my-zsh-plugins` (via `omz-prompt` module) — raw `ZSH_THEME` mechanism: `plugin-implementation.md#theme-loading` |
| Configuration / NVM Lazy Loading | `using-plugins.md#configuring-shipped-modules` (example) + `modules.md#nodejs` |
| Troubleshooting / Non-Interactive Mode | `using-plugins.md#troubleshooting` |
| Troubleshooting / Completion Issues | `using-plugins.md#troubleshooting` |

## docs/caching-implementation.md (deleted)

implementation.md already contained a current Caching System section
duplicating this file's accurate content; the unique remainder had rotted
(pre-restructure paths `~/.config/zsh/zdot` and `lib/`, example functions
`git-status`/`git-branch` that never shipped, hardcoded file counts).

| Old section | Destination |
|---|---|
| Overview / Architecture / Three-Tier Caching Strategy | `implementation.md#caching-system` + `implementation.md#architecture` |
| Configuration (enable/disable, zstyle keys) | `implementation.md#configuration` + `zstyle-reference.md#cache--zdotcache` |
| Directory Structure (source vs compiled) | `implementation.md#cache-file-locations` |
| Implementation Details (`zdot_cache_compile_file`, `zdot_cache_compile_functions`) | `implementation.md#cache-creation` |
| Module Loading Pipeline / `_zdot_source_module` | `implementation.md#module-loading-pipeline` |
| Module Authoring Helpers (`zdot_module_source`, `zdot_module_autoload_funcs`) | `implementation.md#module-loading-1` + `implementation.md#function-loading` + `api-reference.md#zdot_module_source` |
| How It Works / Why Co-location Works | `implementation.md#why-co-location` |
| Cache Management (create/update/invalidate) | `implementation.md#cache-invalidation` |
| Debugging and Troubleshooting | `implementation.md#troubleshooting` |
| Bug Fixes (2026-02-15 changelog) | dropped: dated fix log; superseded by code, preserved in git history |
| Testing (manual + automated scripts) | dropped: ad-hoc scripts referencing nonexistent functions and stale paths |
| Performance (benchmark tables) | `implementation.md#performance-impact` (summary) — dropped: per-machine benchmark tables; `zdot bench` is the live source |
| Summary | dropped: restated the file's own key principles |

## docs/module-guide.md (pruned in place)

| Old section | Destination |
|---|---|
| Predefined groups: barrier scheduling internals (synthetic edges, force-defer cascade) | `implementation.md#predefined-group-scheduling-pre-defer-and-finally` |
| API Reference (trailing summary tables) | dropped: stale duplicate of `api-reference.md#table-of-contents`; replaced by `module-guide.md#further-reference` pointer |

## docs/plugin-implementation.md (pruned in place)

| Old section | Destination |
|---|---|
| Bundle Handler Interface Contract | `advanced.md#writing-a-bundle-handler` |
| Writing a New Bundle Handler (skeleton) | `advanced.md#writing-a-bundle-handler` |

## docs/api-reference.md (corrected in place)

| Old section | Destination |
|---|---|
| CLI table (invented verbs: `plugin remove`, `module hooks`, `completion dir`, `update check/run`, `cache stats`) | `api-reference.md#cli` corrected against the dispatcher — canonical: `commands.md#quick-reference` |

## docs/commands.md (extended in place)

| Change | Destination |
|---|---|
| Missing nouns/verbs vs dispatcher (`update`, `phase`, `hook status`, `hook defer-queue`) | `commands.md#update` + `commands.md#phase` + `commands.md#hook` |

## docs/design/ (2026-06-10 pass — distill to decision records)

Retired docs are deleted; full text remains in git history. Transcripts and
journals were distilled wholesale (no per-heading coverage — their headings
are conversation-turn markers), validated by the five code-vs-doc audit
agents whose findings the decision records encode.

| Retired doc | Destination |
|---|---|
| update-rework.md (one-liner) | `design/update-architecture.md#what-the-designs-proposed-and-why-it-changed` |
| update-rework2.md (journal) | `design/update-architecture.md#what-the-designs-proposed-and-why-it-changed` |
| update-rework3.md | `design/update-architecture.md#rename-map-design-name--shipped-name` |
| self-update.md (spec) | `design/update-architecture.md#what-shipped` + rename map |
| omz-integration-analysis.md | `design/compinit-caching-decisions.md#where-this-started` + `design/compinit-caching-decisions.md#residue` |
| cache-invalidation-refactor.md | `design/compinit-caching-decisions.md#what-shipped-and-how-it-differs-from-the-proposal` (all four changes, with the corrected metadata outcome) |
| fix-validation-report.md | `design/compinit-caching-decisions.md#verification-history` — dropped: point-in-time sample data |
| api-improve.md (journal) | `design/api-naming-and-sugar.md` (naming rationale, circular-dependency learning) — dropped: debugging transcript bulk |
| api-improve-plan.md | `design/api-naming-and-sugar.md#what-shipped` + `design/api-naming-and-sugar.md#deferred-cleanup-from-the-plans-chunk-5` |
| api-improvements.md (brainstorm) | `design/open-questions.md#batch-plugin-declaration-ergonomics` — rest overtaken (noted in `design/api-naming-and-sugar.md`) |
| module-improvements.md | `design/open-questions.md#examples-directory-for-personal-module-patterns` — completed audit now reflected in `modules.md` / `zstyle-reference.md` |
| ssh-issue.md (transcript) | `design/open-questions.md#ghostty-ssh--g-hang-inside-process-substitution` (condensed: symptom, suspects, next steps) |
| extract-zdot.md (transcript) | `design/update-architecture.md#repo-extraction-note` |

Kept in place (with validated status banners): `design/plugin-hook-architecture.md`,
`design/user-variant-context.md`, `design/prezto-bundle.md`,
`design/compdump-and-clone-fastpath.md`; index: `design/README.md`.

## Unchanged

`compinit.md`, `zstyle-reference.md` (extended: history/prompts/plugin-update/
syntax-highlight/update-nag/ai sections, Round terminology, fixed anchors),
`modules.md` (extended: ai, patina, syntax-highlight, update-nag, vim-mode;
dropped `old-plugins` row — module no longer exists on disk),
`implementation.md` (dropped: removed-API `zdot_load_modules` historical
listing and stale source line numbers).
