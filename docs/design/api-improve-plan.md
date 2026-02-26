# API Improvement Plan

Status: **Complete**
Backup: `git stash@{0}` — "WIP split plugins (WORKING)"

## Overview

Split monolithic `lib/plugins/plugins.zsh` into per-concern modules, introduce
`zdot_define_module` and `zdot_simple_hook` sugar, rename APIs to verb-first
convention, fix bugs, update documentation.

---

## Chunk 1: Simple Renames -- DONE

Each rename: added new name as the real function, kept old name as a deprecation
shim that warns and delegates. Updated all call sites to use the new name.

| Old Name | New Name | Files | Status |
|----------|----------|-------|--------|
| `zdot_bundle_register` | `zdot_register_bundle` | 3 | Done |
| `zdot_completion_register_file` | `zdot_register_completion_file` | 5 | Done |
| `zdot_completion_register_live` | `zdot_register_completion_live` | 1 | Done |
| `zdot_user_module_load` | `zdot_load_user_module` | 1 | Done |
| `zdot_module_load` | `zdot_load_module` | 2 + .zshrc | Done |
| `zdot_accept_deferred` | `zdot_allow_defer` | 2 + .zshrc | Done |

---

## Chunk 2: Large Renames -- DONE

| Old Name | New Name | Files | Replacements | Status |
|----------|----------|-------|-------------|--------|
| `zdot_hook_register` | `zdot_register_hook` | 28 | ~61 | Done |
| `zdot_use` | `zdot_use_plugin` | 7 | 25 | Done |

---

## Chunk 3: Bug Fixes -- DONE

### 3a. `prompt.zsh` line 1 typo -- FIXED
Stray `x` prefix on shebang line.

### 3b-3c. Empty hook function + duplicate hooks -- RESOLVED
Root cause: all 6 warnings were artifacts of the test command
`zsh -c 'source zdot.zsh && zdot_init'` which double-sourced zdot.zsh.
In normal shell usage (via .zshenv symlink), zero warnings.

**Defense-in-depth fixes applied:**
- Idempotent `zdot_init()` guard (`_ZDOT_INIT_DONE`)
- `REPLY` set on duplicate hook in `zdot_register_hook` (returns existing ID)

---

## Chunk 4: Module Conversions -- DONE

### `zdot_define_module` enhancements
- Fixed phantom-token bug (post-init without load phase)
- Added `--post-init-requires`, `--post-init-context`
- Added `--configure-context`, `--load-context`

### `zdot_simple_hook` -- NEW
Convention-over-configuration helper for single-hook modules.
Defaults: fn=`_<name>_init`, requires=`xdg-configured`,
provides=`<name>-configured`, contexts=both.

### Conversion summary

| Sugar | Modules | Count |
|-------|---------|-------|
| `zdot_define_module` | tmux, nodejs, shell-extras, fzf (x2), autocomplete | 6 calls |
| `zdot_simple_hook` | sudo, env, shell, bun, rust, ssh, aliases, keybinds, brew, apt, uv, local_rc, mcp, dotfiler | 14 calls |
| Manual (stays) | xdg, prompt, secrets, completions, venv, plugins | 5 modules |

### Not converted (by design)
- **xdg**: Foundation module, zero requires, cleanup hook uses `--group finally`
- **prompt**: Uses `--deferred-prompt`, `--requires-tool oh-my-posh`
- **secrets**: Uses `--requires-tool op`, complex init logic
- **completions**: Two-phase pipeline with external cross-module requires
- **venv**: Two-phase pipeline with `--optional` soft dependency

### `plugins.zsh` residual
Left as-is per user decision. Contains `_omz_configure_update` (omz-configure
group hook) and `zdot_use_plugin omz:lib` declaration.

---

## Chunk 5: Cleanup -- DONE

### Documentation updates
- README.md: renamed all API references, added sugar function docs
- docs/COMMANDS.md: renamed API references
- docs/PLUGINS.md: renamed API references, updated API table
- docs/IMPLEMENTATION.md: renamed 44 references, added sugar mention
- docs/PLUGIN_IMPLEMENTATION.md: renamed references, updated phase chain note

### Still pending (deferred)
- Remove `lib/plugins/plugins.zsh.bak` (backup file)
- Update module header comments (some still say "Plugins: zdot-plugins manager setup")
- Fold `zdot_use_fpath`/`zdot_use_path` into `zdot_use_plugin` (API change)
- Remove `zdot_use_defer` definition (when no callers remain)
- Full interactive shell test (noninteractive passes clean)
