# Compinit and Compaudit Controls

`core/compinit.zsh` manages the zsh completion system (`compinit`).  This
document describes the knobs available to control **compaudit** — the security
check that scans `$fpath` for world- or group-writable directories.

---

## Background

`compinit -i` (the default) skips completion functions in insecure directories
silently.  `compinit -u` trusts all directories without checking.  On most
personal machines the audit is harmless but adds a small startup cost; on shared
or managed systems the warnings can be actionable.

---

## Controls

### 1. zstyle (highest priority)

```zsh
# Skip the audit — use compinit -u
zstyle ':zdot:compinit' skip-compaudit true

# Force the audit — use compinit -i (default when unset)
zstyle ':zdot:compinit' skip-compaudit false
```

Set this in your `~/.zshrc` (or any file sourced before compinit runs).

`zstyle -t` is used internally, so any value that zstyle considers "true"
(`true`, `yes`, `1`, `on`) enables the skip; anything else (including unset)
keeps the audit active.

### 2. ZDOT_SKIP_COMPAUDIT env var (lower priority)

```zsh
export ZDOT_SKIP_COMPAUDIT=true    # skip audit
export ZDOT_SKIP_COMPAUDIT=false   # keep audit (also the default when unset)
```

Accepted truthy values: `1`, `y`, `yes`, `t`, `true`, `on` (case-insensitive).
Any other value (including unset) means "keep audit".

The zstyle setting takes precedence over this variable.

### 3. ZSH_DISABLE_COMPFIX (deprecated, for compatibility)

The OMZ-style `ZSH_DISABLE_COMPFIX` variable is still honoured:

```zsh
export ZSH_DISABLE_COMPFIX=true    # skip audit (OMZ convention)
```

Only consulted when neither the zstyle nor `ZDOT_SKIP_COMPAUDIT` is set.
Prefer `ZDOT_SKIP_COMPAUDIT` or the zstyle in new configurations.

---

## Priority order

```
zstyle ':zdot:compinit' skip-compaudit   ← checked first
ZDOT_SKIP_COMPAUDIT                      ← checked second
ZSH_DISABLE_COMPFIX                      ← deprecated fallback
(default: audit active, compinit -i)     ← when nothing is set
```

---

## Insecure-directory warnings

When the audit is active (`compinit -i`) and insecure directories are found,
`zdot_handle_completion_insecurities` runs in the background and prints:

```
[zdot] Insecure completion-related directories found:
  /usr/local/share/zsh/site-functions
  …

  To fix, run:  compaudit | xargs chmod g-w,o-w

  Or skip the audit entirely by setting one of:
    ZDOT_SKIP_COMPAUDIT=true
    zstyle ':zdot:compinit' skip-compaudit true
```

---

## Fast path (cached dump)

When the compdump is fresh, `compinit -C` is used — this bypasses the dump
regeneration **and** skips the audit entirely, regardless of the controls
above.  The controls only apply when a full `compinit` run is triggered.

---

## Forcing a full refresh

```zsh
_ZDOT_FORCE_COMPDUMP_REFRESH=1 zsh   # next shell start does a full compinit
```
