# zdot Self-Update Design

## Overview

zdot needs a self-contained update system that is separable from dotfiler but can
share dotfiler's symlink machinery when available. The update system handles two
deployment scenarios:

1. **Standalone**: `$ZDOT_DIR` is its own git repo root. zdot does `git pull` and
   applies symlinks to a configurable `destdir`.
2. **Submodule inside dotfiler**: `$ZDOT_DIR` is a subdirectory (or registered
   submodule) of a parent dotfiles repo. zdot runs `git submodule update --remote`
   from the parent root, then applies symlinks. The parent repo's dirty submodule
   pointer is handled per configuration.
3. **Plain subdir** (edge case): `$ZDOT_DIR` is a plain tracked subdir of the
   parent repo. Updates are the parent repo's responsibility; zdot hints that
   the user should disable self-update (`zstyle ':zdot:update' mode disabled`).

The update system is **opt-in by default**: users must set
`zstyle ':zdot:update' mode` to something other than `disabled` to activate it.

### Deployment scenario 4: defer entirely to dotfiler

If zdot is part of a dotfiler-managed repo and the user is happy with dotfiler's
own `check_update.sh` / `update.sh` cycle handling everything (including zdot
files), they simply leave zdot's update mode as `disabled`. dotfiler already
handles the `git pull` of the parent repo and re-symlinks all changed files via
`setup.sh`. In this scenario zdot's self-update system is a no-op and there is
zero overhead. This is the recommended setup for integrated dotfiler users who
do not need zdot-specific update control (e.g. submodule pointer management or
a separate update frequency).

---

## Configuration (zstyle reference)

All zstyles are unset by default. The update system exits immediately if
`':zdot:update' mode` is unset or `disabled`.

```zsh
# Primary mode control (MUST be set to activate updates)
zstyle ':zdot:update' mode      disabled  # prompt | auto | reminder | disabled

# How often to check for updates (seconds, default 3600)
zstyle ':zdot:update' frequency 3600

# Where symlinks are planted (default: ~/.config/zdot)
zstyle ':zdot:update' link-dest "${XDG_CONFIG_HOME:-$HOME/.config}/zdot"

# Source repo dir (default: $ZDOT_DIR, auto-detected)
zstyle ':zdot:update' repo-dir  ""

# What to do with the parent repo's dirty submodule pointer after update
# only relevant in submodule mode
zstyle ':zdot:update' submodule-pointer  none  # none | prompt | auto

# Path to dotfiler scripts/ dir (auto-detected if empty)
zstyle ':zdot:dotfiler' scripts-dir  ""
```

---

## Deployment Detection

Performed once at activation time by `_zdot_update_detect_mode()`:

```
zdot_git_root = git -C "$ZDOT_DIR" rev-parse --show-toplevel

if zdot_git_root == ZDOT_DIR (realpath):
    mode = standalone

elif git -C zdot_git_root submodule status "$ZDOT_DIR" succeeds:
    mode = submodule
    parent_root = zdot_git_root

else:
    mode = subdir   # has own remote but lives inside another repo
    parent_root = zdot_git_root
```

In `subdir` mode zdot does **not** pull at all — the parent repo manages
updates. zdot writes the timestamp, logs a hint to disable self-update
(`zstyle ':zdot:update' mode disabled`), and returns early.

---

## dotfiler Scripts Discovery

`_zdot_update_find_dotfiler_scripts()` — returns path to dotfiler `scripts/` dir
in `REPLY`, or returns 1 if not found.

Priority order:

1. `zstyle ':zdot:dotfiler' scripts-dir` override (explicit path)
2. Parent repo (in submodule/subdir mode) contains `scripts/setup.sh`
3. dotfiler loaded as a zdot plugin: `zdot_plugin_path georgeharker/dotfiler`
   and `$REPLY/scripts/setup.sh` exists
4. Not found → warn, fall back to inline minimal symlink logic

### dotfiler as a zdot plugin

When zdot is standalone and the user wants dotfiler's symlink machinery, they
declare dotfiler as a zdot plugin:

```zsh
zdot_use_plugin georgeharker/dotfiler hook
```

The plugin hook declaration ensures that `zdot_use_bundle` registers the repo so
the clone is not treated as an orphan by `zdot_clean_plugins`. The discovery
function in `core/update.zsh` locates the scripts directly in the plugin cache.

---

## Phase 1: setup.sh Modifications (dotfiler)

### Goal

Make `setup.sh` accept two new options so it can operate on an arbitrary source
repo and plant symlinks at an arbitrary destination, while preserving 100%
backward compatibility when neither option is supplied.

### Variable name constraints

The following names are already in use inside `setup.sh` and MUST NOT be reused
as the new script-level parameter variable names:

| Existing name | Scope | Used for |
|---|---|---|
| `src` | local (many functions) | source file path in link/copy ops |
| `dest` | local (many functions) | destination file path in link/copy ops |
| `destdir` | local (`dolink`, `copy_in_if_needed`) | `${dest:h}` — parent dir of dest |
| `dotfiles_dir` | script-level | current source root (set from `find_dotfiles_directory`) |

### New parameter names

| New option | Script-level variable | Default | Replaces |
|---|---|---|---|
| `--repo-dir <path>` | `_setup_repo_dir` | result of `find_dotfiles_directory()` | `dotfiles_dir` throughout |
| `--link-dest <path>` | `_setup_link_dest` | `$HOME` | `$HOME` at all dest-computation sites |

After parsing, set `dotfiles_dir=$_setup_repo_dir` so all existing internal
functions that reference `dotfiles_dir` continue to work without further change.
Only the dest-path sites need explicit `$HOME` → `$_setup_link_dest` substitution.

### Sites requiring `$HOME` → `$_setup_link_dest`

| Function / block | Line (approx) | Change |
|---|---|---|
| `normalize_path_to_home_relative` | ~198 | `fullpath_home=${HOME:A}` → `${_setup_link_dest:A}`; rename fn or add alias |
| `link_if_needed` | ~322 | `dest=$HOME/...` → `dest=$_setup_link_dest/...` |
| `copy_in_if_needed` | ~370–374 | `fullpath_home=${HOME:A}`, `src=${fullpath_home}/...` → use `$_setup_link_dest` |
| `untrack_if_needed` | ~462 | `home_path=${HOME}/...` → `$_setup_link_dest/...` |
| `setup` block | ~660 | `find $HOME` → `find $_setup_link_dest` |

### `normalize_path_to_home_relative` rename

This function name is semantically wrong once `$HOME` is no longer the fixed
root. Rename to `normalize_path_to_dest_relative` and update all call sites.
The old name can be kept as an alias for one release if needed.

### zparseopts additions

```zsh
zparseopts ... \
    -repo-dir:=opt_repo_dir \
    -link-dest:=opt_link_dest \
    ...

_setup_repo_dir=${opt_repo_dir[-1]:-}
_setup_link_dest=${opt_link_dest[-1]:-$HOME}
[[ -z "$_setup_repo_dir" ]] && _setup_repo_dir=$(find_dotfiles_directory)
dotfiles_dir=$_setup_repo_dir
```

### Backward compatibility guarantee

- All existing callers (`update.sh`, manual invocations) pass neither option →
  `_setup_link_dest=$HOME`, `_setup_repo_dir` from `find_dotfiles_directory()` →
  identical behavior to today.
- `--dry-run` mode tests both old and new paths before merging.

---

## Phase 2: update.sh Modifications (dotfiler)

`update.sh` calls `setup.sh -u <files>` internally. It must forward `--repo-dir`
and `--link-dest` through to that call.

### Changes

- Add `--repo-dir:` and `--link-dest:` to `update.sh`'s own `zparseopts`
- Store in `_update_repo_dir` / `_update_link_dest` (avoid collisions with
  existing locals `src`, `dest`, `destdir` present in `update.sh` too)
- Pass them through: `setup.sh --repo-dir "$_update_repo_dir" --link-dest "$_update_link_dest" -u ...`
- Default `_update_repo_dir` from `find_dotfiles_directory()` and
  `_update_link_dest` from `$HOME` — identical to current behavior when omitted

### Backward compatibility

No existing caller passes these flags → defaults kick in → no behavioral change.

---

### Detection function (in core/update.zsh)

```zsh
_zdot_update_find_dotfiler_scripts() {
    local _reply
    # 1. Explicit zstyle override
    zstyle -s ':zdot:dotfiler' scripts-dir _reply
    if [[ -n "$_reply" && -f "$_reply/setup.sh" ]]; then
        REPLY=$_reply; return 0
    fi
    # 2. Are we inside a parent repo that has dotfiler scripts?
    local _root
    _root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$_root" && -f "$_root/scripts/setup.sh" ]]; then
        REPLY="$_root/scripts"; return 0
    fi
    # 3. Try plugin cache path directly
    local _cache="${_ZDOT_PLUGINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zdot/plugins}"
    local _candidate="$_cache/georgeharker/dotfiler/scripts"
    if [[ -f "$_candidate/setup.sh" ]]; then
        REPLY=$_candidate; return 0
    fi
    REPLY=""; return 1
}
```

---

## Phase 4: core/update.zsh — Skeleton and Activation

### File location

`core/update.zsh` — sourced from `zdot.zsh` unconditionally, after
`core/plugins.zsh`. The file exits immediately if mode is `disabled` (the
default), so there is zero cost when the user has not opted in.

### Activation in zdot.zsh

```zsh
source "${0:A:h}/core/update.zsh"
```

Added after the `source .../core/plugins.zsh` line.

### zstyle reference (all defaults shown)

```zsh
# Update mode — MUST be set to something other than 'disabled' to activate
# Values: disabled | reminder | prompt | auto
zstyle ':zdot:update' mode         disabled

# Frequency: minimum seconds between update checks (default 1 hour)
zstyle ':zdot:update' frequency    3600

# destdir: where zdot files are symlinked to
# Default: ~/.config/zdot  (i.e. $ZDOT_DIR itself — a no-op symlink round-trip
#           unless zdot is installed elsewhere and linked into ~/.config/zdot)
zstyle ':zdot:update' destdir      "${XDG_CONFIG_HOME:-$HOME/.config}/zdot"

# submodule-pointer: what to do with dirty parent repo after submodule update
# Values: none | prompt | auto
zstyle ':zdot:update' submodule-pointer  none

# dotfiler scripts dir override (auto-detected if empty)
zstyle ':zdot:dotfiler' scripts-dir  ""
```

### Function inventory

All functions are prefixed `_zdot_update_` and unset after the update check
runs — same cleanup pattern as dotfiler's `check_update.sh`.

```
_zdot_update_current_epoch          zsh/datetime EPOCHSECONDS
_zdot_update_get_default_remote     git branch.<current>.remote fallback
_zdot_update_get_default_branch     symbolic-ref / git remote show / main|master
_zdot_update_is_available           git fetch + HEAD compare
_zdot_update_write_timestamp        write epoch + exit status to timestamp file
_zdot_update_acquire_lock           mkdir lock; stale cleanup >24h
_zdot_update_release_lock           rmdir lock
_zdot_update_find_dotfiler_scripts  4-step detection (Phase 3)
_zdot_update_detect_deployment      standalone | submodule | subdir | none
_zdot_update_apply                  diff old..new → delete symlinks + setup.sh -u
_zdot_update_standalone_apply       git pull + apply
_zdot_update_submodule_apply        git submodule update --remote + apply
_zdot_update_handle_submodule_ptr   none | prompt | auto-commit parent
_zdot_update_has_typed_input        zsh/zselect stdin poll (from check_update.sh)
_zdot_update_handle_update          top-level orchestration
_zdot_update_cleanup                unset -f all of the above
```

### Wiring into the hook system

The update check must run after all plugins, secrets, and shell init are
complete — equivalent to dotfiler's "last thing sourced in `_dotfiler_init`".

```zsh
zdot_register_hook _zdot_update_handle_update \
    --name zdot-update \
    --context interactive \
    --group finally
```

`--group finally` ensures it runs after the full deferred hook drain.

---

## Phase 5: Check / Fetch / Lock / Timestamp Logic

### Timestamp file and lock dir

```
Timestamp: ${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zdot_update
Lock dir:  ${XDG_CACHE_HOME:-$HOME/.cache}/zdot/update.lock
Cache dir: ${XDG_CACHE_HOME:-$HOME/.cache}/zdot/
```

Separate from dotfiler's `~/.cache/dotfiles/` to keep concerns fully isolated.

### Lock protocol (mirrors check_update.sh exactly)

```zsh
_zdot_update_acquire_lock() {
    local lock_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/update.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # Stale lock cleanup: remove if older than 24h
        local lock_age=$(( $(date +%s) - $(zstat +mtime "$lock_dir" 2>/dev/null || echo 0) ))
        (( lock_age > 86400 )) && rm -rf "$lock_dir" && mkdir "$lock_dir" 2>/dev/null || return 1
    fi
    return 0
}
_zdot_update_release_lock() {
    rmdir "${XDG_CACHE_HOME:-$HOME/.cache}/zdot/update.lock" 2>/dev/null
}
```

### Timestamp format

Same as dotfiler's:

```
LAST_EPOCH=<epoch>
EXIT_STATUS=<0|non-zero>   # written only on non-zero
ERROR=<message>            # written only on error
```

### Frequency check

```zsh
local _ts_file="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zdot_update"
local _last_epoch=0
[[ -f "$_ts_file" ]] && source "$_ts_file"    # sets LAST_EPOCH
local _freq; zstyle -s ':zdot:update' frequency _freq; _freq=${_freq:-3600}
local _now=$(_zdot_update_current_epoch)
(( _now - _last_epoch < _freq )) && return 0  # too soon, skip
```

### is_available: fetch + HEAD compare

```zsh
_zdot_update_is_available() {
    local _remote _branch _local_sha _remote_sha
    _remote=$(_zdot_update_get_default_remote)
    _branch=$(_zdot_update_get_default_branch "$_remote")
    git -C "$ZDOT_DIR" fetch "$_remote" "$_branch" --quiet 2>/dev/null || return 2
    _local_sha=$(git -C "$ZDOT_DIR" rev-parse HEAD)
    _remote_sha=$(git -C "$ZDOT_DIR" rev-parse "$_remote/$_branch" 2>/dev/null) || return 2
    [[ "$_local_sha" != "$_remote_sha" ]]   # 0=update available, 1=up to date
}
```

---

## Phase 6: Apply Logic

### _zdot_update_apply old_sha new_sha

This function is called after any pull/submodule-update succeeds and the SHA
has changed. It uses dotfiler's `setup.sh` with the new options from Phase 1.

```zsh
_zdot_update_apply() {
    local _old=$1 _new=$2
    local _scripts_dir _destdir _link_dest

    zstyle -s ':zdot:update' destdir _destdir
    _destdir=${_destdir:-${XDG_CONFIG_HOME:-$HOME/.config}/zdot}

    _zdot_update_find_dotfiler_scripts   # sets REPLY
    _scripts_dir=$REPLY

    # Build lists from git diff
    local -a _added _removed
    while IFS=$'\t' read -r _status _file; do
        case $_status in
            A|M|C*|R*) _added+=("$_file") ;;
            D)          _removed+=("$_file") ;;
        esac
    done < <(git -C "$ZDOT_DIR" diff --name-status "$_old" "$_new")

    # Remove deleted symlinks
    local _f _dest_path
    for _f in "${_removed[@]}"; do
        _dest_path="$_destdir/$_f"
        [[ -L "$_dest_path" ]] && rm -f "$_dest_path"
    done

    # Apply added/modified via dotfiler setup.sh or inline fallback
    if [[ -n "$_scripts_dir" && -x "$_scripts_dir/setup.sh" ]]; then
        (( ${#_added[@]} > 0 )) && \
            zsh -f "$_scripts_dir/setup.sh" \
                --repo-dir "$ZDOT_DIR" \
                --link-dest "$_destdir" \
                -u "${_added[@]}"
    else
        # Inline fallback: plain symlink, no exclusion/conflict logic
        _zdot_update_apply_inline "$_destdir" "${_added[@]}"
    fi
}
```

### Inline fallback

Only used when dotfiler scripts are not found. Minimal: no exclusion patterns,
no conflict detection, no dry-run. Creates symlinks only.

```zsh
_zdot_update_apply_inline() {
    local _destdir=$1; shift
    local _f _src _dest _destparent
    for _f in "$@"; do
        _src="$ZDOT_DIR/$_f"
        _dest="$_destdir/$_f"
        _destparent="${_dest:h}"
        [[ -d "$_destparent" ]] || mkdir -p "$_destparent"
        ln -sf "$_src" "$_dest"
    done
}
```

---

## Phase 7: Pull Paths

### Deployment detection

```zsh
_zdot_update_detect_deployment() {
    # REPLY = standalone | submodule | subdir | none
    local _zdot_root _parent_root _zdot_real
    _zdot_root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null) || {
        REPLY=none; return 0
    }
    _zdot_real=${ZDOT_DIR:A}
    if [[ "${_zdot_root:A}" == "$_zdot_real" ]]; then
        REPLY=standalone; return 0
    fi
    # zdot is inside a parent repo
    _parent_root=${_zdot_root:A}
    local _rel=${_zdot_real#$_parent_root/}
    if git -C "$_parent_root" submodule status "$_rel" &>/dev/null; then
        REPLY=submodule; return 0
    fi
    REPLY=subdir; return 0   # plain tracked subdir — parent repo manages updates
}
```

### Standalone path

```zsh
_zdot_update_standalone_apply() {
    local _old _new
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD)
    git -C "$ZDOT_DIR" pull --quiet || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse HEAD)
    [[ "$_old" != "$_new" ]] && _zdot_update_apply "$_old" "$_new"
}
```

### Submodule path

```zsh
_zdot_update_submodule_apply() {
    local _parent_root _rel _old _new
    _parent_root=$(git -C "$ZDOT_DIR" rev-parse --show-toplevel 2>/dev/null)
    _rel=${${ZDOT_DIR:A}#${_parent_root:A}/}
    _old=$(git -C "$ZDOT_DIR" rev-parse HEAD)
    git -C "$_parent_root" submodule update --remote -- "$_rel" || return 1
    _new=$(git -C "$ZDOT_DIR" rev-parse HEAD)
    [[ "$_old" != "$_new" ]] && _zdot_update_apply "$_old" "$_new"
    _zdot_update_handle_submodule_ptr "$_parent_root" "$_rel" "$_new"
}
```

### Submodule pointer handling

```zsh
_zdot_update_handle_submodule_ptr() {
    local _parent=$1 _rel=$2 _new=$3
    local _mode
    zstyle -s ':zdot:update' submodule-pointer _mode
    case ${_mode:-none} in
        auto)
            git -C "$_parent" add "$_rel"
            git -C "$_parent" commit -m "zdot: update submodule to ${_new[1,12]}"
            ;;
        prompt)
            _zdot_update_has_typed_input && return
            print -n "zdot: commit updated submodule pointer in parent repo? [y/N] "
            read -r -k1 _ans; print ""
            [[ "$_ans" == (y|Y) ]] && {
                git -C "$_parent" add "$_rel"
                git -C "$_parent" commit -m "zdot: update submodule to ${_new[1,12]}"
            }
            ;;
        none|*)
            print "zdot: submodule updated; parent repo is dirty (commit pointer manually)"
            ;;
    esac
}
```

---

## Phase 8: Orchestration, Cleanup, and Hook Wiring

### _zdot_update_handle_update (top-level)

```zsh
_zdot_update_handle_update() {
    # 1. Read mode; exit early if disabled
    local _mode
    zstyle -s ':zdot:update' mode _mode
    [[ "${_mode:-disabled}" == disabled ]] && return 0

    # 2. Early-exit guards
    [[ -d "$ZDOT_DIR" ]] || return 0
    command -v git &>/dev/null || return 0
    git -C "$ZDOT_DIR" rev-parse --is-inside-work-tree &>/dev/null || return 0

    # 3. Acquire lock
    _zdot_update_acquire_lock || return 0

    # 4. Frequency check (reads timestamp file)
    local _ts="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/zdot_update"
    local LAST_EPOCH=0
    [[ -f "$_ts" ]] && source "$_ts"
    local _freq; zstyle -s ':zdot:update' frequency _freq; _freq=${_freq:-3600}
    local _now; _now=$(_zdot_update_current_epoch)
    if (( _now - LAST_EPOCH < _freq )); then
        _zdot_update_release_lock; return 0
    fi

    # 5. Check for update
    _zdot_update_is_available
    local _avail=$?
    if (( _avail != 0 )); then
        _zdot_update_write_timestamp $_avail ""
        _zdot_update_release_lock
        return 0
    fi

    # 6. Detect deployment type
    _zdot_update_detect_deployment   # sets REPLY
    local _deploy=$REPLY

    # 7. Dispatch by mode
    case $_mode in
        reminder)
            print "zdot: update available (run: git -C \$ZDOT_DIR pull)"
            _zdot_update_write_timestamp 0 ""
            ;;
        auto)
            [[ "$_deploy" == submodule ]] && _zdot_update_submodule_apply \
                || _zdot_update_standalone_apply
            _zdot_update_write_timestamp $? ""
            ;;
        prompt)
            _zdot_update_has_typed_input || {
                print -n "zdot: update available. Pull now? [Y/n] "
                read -r -k1 _ans; print ""
                if [[ "$_ans" != (n|N) ]]; then
                    [[ "$_deploy" == submodule ]] && _zdot_update_submodule_apply \
                        || _zdot_update_standalone_apply
                    _zdot_update_write_timestamp $? ""
                fi
            }
            ;;
    esac

    _zdot_update_release_lock
}
```

### Cleanup

```zsh
_zdot_update_cleanup() {
    unset -f \
        _zdot_update_current_epoch \
        _zdot_update_get_default_remote \
        _zdot_update_get_default_branch \
        _zdot_update_is_available \
        _zdot_update_write_timestamp \
        _zdot_update_acquire_lock \
        _zdot_update_release_lock \
        _zdot_update_find_dotfiler_scripts \
        _zdot_update_detect_deployment \
        _zdot_update_apply \
        _zdot_update_apply_inline \
        _zdot_update_standalone_apply \
        _zdot_update_submodule_apply \
        _zdot_update_handle_submodule_ptr \
        _zdot_update_has_typed_input \
        _zdot_update_handle_update \
        _zdot_update_cleanup
}
```

Called at the bottom of `core/update.zsh`, after the hook is registered.
The hook body captures the function references before cleanup runs.

---

## Risk Register

| Risk | Mitigation |
|---|---|
| `setup.sh --repo-dir/--link-dest` breaks existing dotfiler users | Defaults identical to current behavior; test with `--dry-run` first |
| `normalize_path_to_home_relative` rename breaks callers | All 6 call sites are internal to `setup.sh`; renamed atomically, no alias needed |
| `git submodule update --remote` on wrong path | Validate `_rel` exists as registered submodule before running |
| `auto` pointer commit surprises user | Default is `none`; user must explicitly opt in |
| dotfiler plugin clone fails (no network at startup) | Graceful fallback to inline symlink logic; warn clearly |
| Update check runs before secrets loaded | `--group finally` in hook system ensures last |
| zdot inside parent repo but not a submodule (`subdir` mode) | No-op: hint to disable self-update; parent repo manages updates |
| `_zdot_update_*` functions leak if `handle_update` errors out | `_zdot_update_cleanup` called in a `trap ... EXIT` inside the scope |

---

## Implementation Order

1. `setup.sh`: add `--repo-dir` / `--link-dest` (rename to `normalize_path_to_dest_relative` done)
2. `update.sh`: forward new options to `setup.sh`
3. `core/update.zsh`: full implementation (Phases 4–8 above)
4. `zdot.zsh`: add `source core/update.zsh`
5. Docs: mark item 3 done in `api-improvements.md`

Each step is independently reviewable via `git diff` before proceeding.
