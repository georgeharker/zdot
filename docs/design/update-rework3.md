# Self-Update Timestamp Gating — Design

## Goal

Add timestamp/interval gating to the dotfiler self-update path (`update_self.sh`)
so it skips the git pull if checked recently — matching the behaviour already
implemented for user dotfiles in `check_update.sh`. The self-update check should
also trigger on **shell start** via `check_update.sh` (not only on explicit
`dotfiler update-self`).

---

## Approach

**Option C:** add shared primitives to `update_core.sh`, call them from both
`check_update.sh` and `update_self.sh`.

---

## Architecture

```
dotfiler.zsh  (zdot module, shell start)
  └── check_update.sh          ← Steps 1-4
        ├── handle_update()     user dotfiles timestamp/lock/interval/mode
        └── handle_self_update() NEW — dotfiler scripts check on shell start

dotfiler CLI
  └── update_self.sh            ← Steps 5-8
        topology-aware self-update, now with timestamp gate + API-first

update_core.sh                  ← Step 0 (done)
  shared primitives used by both callers
```

**Entrypoint chain:**

- `zdot/lib/dotfiler/dotfiler.zsh` — zdot module; sets
  `zstyle ':dotfiler:update' mode prompt`, sources `check_update.sh` on shell
  start.
- `check_update.sh` — sourced on shell start; implements `handle_update` with
  full timestamp/lock/interval/mode logic for user dotfiles. **Steps 1-4** replace
  the old fetch-first `is_update_available()` with an API-first thin wrap and add
  `handle_self_update()`.
- `update_self.sh` — invoked by `dotfiler update-self` CLI command.
  Topology-aware self-update. **Steps 5-8** add a timestamp gate and switch to
  API-first availability check.
- `update_core.sh` — shared primitives. **Step 0** already added
  `_update_core_is_available`.

---

## Key Design Decisions

### API-first (critical requirement)

Try the GitHub API first (fast, no network side-effects on the repo), fall back
to `git fetch` + local comparison only if the remote is non-GitHub or the API
call fails. Modeled on the
[ohmyzsh reference](https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/refs/heads/master/tools/check_for_upgrade.sh)
which does API-first with a `merge-base` check to handle diverged histories.

### Function signatures and return codes

- **`_update_core_is_available <repo_dir> [<remote_url_override>]`**
  Returns 0 = update available, 1 = up to date or skip (conservative).
  **No return code 2** — all failure cases return 1/skip.

- **API-first logic:** For GitHub remotes, queries
  `https://api.github.com/repos/{owner}/{repo}/commits/{branch}` with
  `Accept: application/vnd.github.v3.sha` header. Uses `merge-base` check:
  `[[ "$_base" != "$_remote_head" ]]` returns 0 when local is behind remote,
  1 when up-to-date or diverged. Falls back to `_update_core_is_available_fetch`
  (git fetch) for non-GitHub remotes.

- **`_update_core_should_update`** — returns 0 = proceed, 1 = skip.
  `force="true"` bypasses the interval check.

### Argument passing convention

Core functions (`update_core.sh`) take **explicit arguments** — no globals, no
zstyle reads. Callers read zstyle and pass resolved values in. **Exception:**
`update_self.sh` is a dotfiler caller script, so it reads zstyle directly.

zstyle namespaces: dotfiler uses `':dotfiler:update'`, zdot uses
`':zdot:update'`.

### Stamp files

- **`check_update.sh`:**
  `${dotfiles_cache_dir}/dotfiler_scripts_update` (uses already-set ambient var)
- **`update_self.sh`:**
  `${XDG_CACHE_DIR:-$HOME/.cache}/dotfiles/dotfiler_scripts_update`
  (computed independently — no ambient vars available)

### Force flag in `update_self.sh`

Stored as integer `_force`, converted to string `"true"`/`"false"` before
passing to `_update_core_should_update`.

---

## Edit Plan

### Step 0 — `update_core.sh`: Replace fetch-first function with API-first  DONE

- Removed `_update_core_is_available_with_api_fallback` (lines 295-365).
- Inserted `_update_core_is_available` in its place (originally named
  `_update_core_is_available_api_first`, later renamed — see Progress).

### Step 0b — `update_core.sh`: Fix `_update_core_cleanup` unset list  DONE

- At line 395 in `_update_core_cleanup`, replace
  `_update_core_is_available_with_api_fallback` with
  `_update_core_is_available`.

### Step 1 — `check_update.sh`: Replace `is_update_available()` body (lines 71-140)

Replace the entire 70-line body with a thin wrap:

```zsh
function is_update_available() {
    _update_core_is_available "$dotfiles_dir"
}
```

The old body did fetch-first with API as fallback. The new
`_update_core_is_available` already does API-first with git-fetch
fallback for non-GitHub remotes.

### Step 2 — `check_update.sh`: Refactor `handle_update()` timestamp block (lines 194-221)

Replace the manual `LAST_EPOCH` sourcing + frequency check block with:

```zsh
    local _dotfiles_freq
    zstyle -s ':dotfiler:update' frequency _dotfiles_freq || _dotfiles_freq=${UPDATE_DOTFILE_SECONDS:-3600}
    if ! _update_core_should_update "$dotfiles_timestamp" "$_dotfiles_freq" "$force_update"; then
        return
    fi
```

Also remove `epoch_target` and `LAST_EPOCH` from the `local` declaration on
line 171 (keep `mtime` and `option`).

### Step 3 — `check_update.sh`: Add `handle_self_update()` after line 265

Insert after `handle_update`'s closing `}`:

```zsh
function handle_self_update() {
    () {
        emulate -L zsh
        local _self_stamp="${dotfiles_cache_dir}/dotfiler_scripts_update"
        local _self_freq
        zstyle -s ':dotfiler:update' frequency _self_freq || _self_freq=${UPDATE_DOTFILE_SECONDS:-3600}

        if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$force_update"; then
            return
        fi

        local _subtree_spec
        zstyle -s ':dotfiler:update' subtree-remote _subtree_spec 2>/dev/null || _subtree_spec=""
        _update_core_detect_deployment "$script_dir" "$_subtree_spec"
        local _topology=$REPLY

        local _avail
        case $_topology in
            standalone|submodule)
                _update_core_is_available "$script_dir"
                _avail=$? ;;
            subtree)
                local _remote_url _remote="${_subtree_spec%% *}"
                _remote_url=$(git -C "$script_dir" config "remote.${_remote}.url" 2>/dev/null)
                _update_core_is_available "$script_dir" "$_remote_url"
                _avail=$? ;;
            subdir|none|*)
                return 0 ;;
        esac

        # _avail==1 means up to date or indeterminate skip -- write stamp and return
        if (( _avail == 1 )); then
            _update_core_write_timestamp "$_self_stamp"
            return
        fi

        zsh -f "${script_dir}/update_self.sh" --force \
            && _update_core_write_timestamp "$_self_stamp"
    }
}
```

### Step 4 — `check_update.sh`: Update dispatch block + unset lists

Four specific changes:

1. **Trap `unset -f` inside `handle_update` (line 187):** add
   `handle_self_update` to the list:
   ```
   unset -f is_update_available update_dotfiles handle_update handle_self_update 2>/dev/null
   ```

2. **Outer `unset -f` after `handle_update` closing `}` (line 262):** add
   `handle_self_update`:
   ```
   unset -f is_update_available update_dotfiles handle_update handle_self_update
   ```

3. **`background-alpha` case `_dotfiles_bg_update()` (line 273):** add
   `(handle_self_update) &|` after `(handle_update) &|`.

4. **`*)` case (line 319):** add `handle_self_update` call after
   `handle_update`:
   ```zsh
   *)
       handle_update
       handle_self_update ;;
   ```

### Step 5 — `update_self.sh`: Parse `-f`/`--force` flag

- Update usage comment on line 10 to mention `-f|--force`.
- Add `local _force=0` before the `for _arg` loop (before line 35).
- Add `-f|--force) _force=1 ;;` inside the `case $_arg in` block (after
  `--dry-run` line).

### Step 6 — `update_self.sh`: Add stamp + frequency locals after line 46

After `_subtree_spec` assignment:

```zsh
local _self_stamp="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiles/dotfiler_scripts_update"
local _self_freq
zstyle -s ':dotfiler:update' frequency _self_freq 2>/dev/null || _self_freq=3600
```

### Step 7 — `update_self.sh`: Insert gate block before `case $_topology in`

Before line 62:

```zsh
local _force_str="false"
(( _force )) && _force_str="true"
if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$_force_str"; then
    info "update_self: scripts checked recently -- skipping (use -f to force)"
    _update_self_exec_update
    return
fi
```

### Step 8 — `update_self.sh`: Switch to API-first + write timestamps

**`standalone` case (around lines 69-88):**
- Call `_update_core_is_available "$script_dir"` (API-first wrapper).
- After successful `git pull`: add
  `(( _dry_run )) || _update_core_write_timestamp "$_self_stamp"`.
- In `_avail == 1` (up to date) branch: add
  `(( _dry_run )) || _update_core_write_timestamp "$_self_stamp"`.
- Remove the `_avail == 2` (fetch error) branch entirely (API-first returns
  only 0 or 1).

**`submodule` case (around lines 112-116):** After `_update_core_commit_parent`
call: add `(( _dry_run )) || _update_core_write_timestamp "$_self_stamp"`.

**`subtree` case (around lines 148-152):** After `_update_core_commit_parent`
call: add `(( _dry_run )) || _update_core_write_timestamp "$_self_stamp"`.

**`subdir`/`none`:** No stamp write needed.

---

## Progress

### Complete

- Design fully worked out and documented.
- **Step 0**: `update_core.sh` — `_update_core_is_available_with_api_fallback`
  replaced with API-first wrapper (now named `_update_core_is_available`).
- **Step 0b**: `update_core.sh` — `_update_core_cleanup` unset list updated.
- **Step 1**: `check_update.sh` — `is_update_available()` wraps
  `_update_core_is_available`.
- **Step 2**: `check_update.sh` — `handle_update()` timestamp block uses
  `_update_core_should_update`.
- **Step 3**: `check_update.sh` — `handle_self_update()` function added.
- **Step 4**: `check_update.sh` — trap unset, outer unset, background-alpha,
  and `*` case all updated.
- **Step 5**: `update_self.sh` — usage comment updated, `-f|--force` flag
  added.
- **Step 6**: `update_self.sh` — stamp + frequency locals added after
  `_subtree_spec` assignment.
- **Step 7**: `update_self.sh` — gate block inserted before
  `case $_topology in`.
- **Step 8**: `update_self.sh` — standalone case switched to API-first with
  timestamp writes; submodule and subtree cases write timestamps after
  `_update_core_commit_parent`.
- **Rename**: `_update_core_is_available` (git-fetch) renamed to
  `_update_core_is_available_fetch`; `_update_core_is_available_api_first`
  renamed to `_update_core_is_available` (now the primary/default name).
  All 10 edit sites across 3 files updated; grep verified zero stale refs.
- **Dead code review**: All three script files read in full — no dead code
  found.
- **Extraction**: `handle_self_update()` extracted from inside
  `handle_update()` to a top-level function with its own lock
  (`self_update.lock`), trap, and cleanup. Call order swapped so
  self-update runs before dotfiles update.
- **Cleanup 1 — shebangs**: `update_self.sh` and `update.sh` shebangs set
  to `#!/bin/zsh` (no `-f`); `check_update.sh` call sites invoke scripts
  directly instead of via `zsh -f`.
- **Cleanup 2 — anonymous functions**: Removed unnecessary `() { ... }`
  wrappers from both `handle_self_update` and `handle_update`; `emulate
  -L zsh` moved to function top.
- **Cleanup 3 — cache separation**: Self-update lock and stamp now live
  under `~/.cache/dotfiler/` (`dotfiler_cache_dir`) instead of sharing
  `~/.cache/dotfiles/`. Updated `check_update.sh` (var, mkdir, lock path,
  stamp path, trap) and `update_self.sh` (stamp path).
- **Trap ordering**: Reordered `handle_self_update` trap so lock release
  happens before `unset dotfiler_cache_dir` for readability (functionally
  equivalent since path is baked in at definition time).

---

## Files

### To be modified

| File | Status |
|------|--------|
| `.nounpack/scripts/update_core.sh` (~402 lines) | Steps 0/0b done, rename applied |
| `.nounpack/scripts/check_update.sh` (~273 lines) | Steps 1-4 done, rename applied |
| `.nounpack/scripts/update_self.sh` (~189 lines) | Steps 5-8 done, rename applied |

### Reference only

| File | Purpose |
|------|---------|
| `.nounpack/scripts/dotfiler` | CLI entrypoint |
| `.nounpack/scripts/update.sh` | ref-walk logic for user dotfiles |
| `.nounpack/scripts/logging.sh` | logging macros (`info`, `warn`, `error`, `verbose`) |
| `.nounpack/scripts/helpers.sh` | helper utilities |
| `.config/zdot/lib/dotfiler/dotfiler.zsh` | sources `check_update.sh` on shell start |
| [ohmyzsh check_for_upgrade.sh](https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/refs/heads/master/tools/check_for_upgrade.sh) | API-first reference implementation |
