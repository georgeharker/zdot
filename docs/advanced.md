# Advanced Usage

Getting more out of zdot: per-context configuration, one rc file for every
shell, per-machine variants, controlling the deferred phase, and extending
the plugin system with your own bundle handler.

This guide assumes you're comfortable with the basics from
[Using Plugins](using-plugins.md) and the
[Module Writer's Guide](module-guide.md).

---

- [Shell contexts](#shell-contexts)
- [One file, two contexts: using `.zshrc` as `.zshenv`](#one-file-two-contexts-using-zshrc-as-zshenv)
- [Variants](#variants)
- [Controlling deferred execution](#controlling-deferred-execution)
- [Writing a bundle handler](#writing-a-bundle-handler)

---

## Shell contexts

Zsh runs your startup files in different scenarios -- an interactive terminal,
a script executed by `zsh -c`, a login shell from SSH. The same configuration
often needs to behave differently in each.

zdot models this with **contexts**. Every hook is registered with one or more
context labels that say when it should run:

| Context | Meaning | Example scenario |
|---------|---------|------------------|
| `interactive` | Shell attached to a user typing commands | `exec zsh`, opening a terminal |
| `noninteractive` | Shell running a command or script | `zsh -c '...'`, `ssh host command` |
| `login` | First shell in a session | `ssh host`, macOS Terminal.app |
| `nonlogin` | Not the session's first shell | Sub-shells, `zsh` inside tmux |

These combine freely. A new terminal tab might be `interactive login`; running
`zsh -c 'make build'` is `noninteractive nonlogin`.

zdot detects the current shell's context once at startup and uses it to filter
the execution plan. Hooks registered for `interactive` never run in a script;
hooks registered for `noninteractive` never fire in your terminal.

### Why this matters

Most modules register for both:

```zsh
zdot_simple_hook mymodule
# Default context: interactive noninteractive
# -> _mymodule_init runs in every shell
```

But some things only make sense interactively -- prompt themes, key bindings,
deferred plugin loading -- while others only matter non-interactively -- like
setting `PATH` for scripts without dragging in the full interactive setup:

```zsh
# Interactive-only: ZLE key bindings require a terminal
zdot_register_hook _keybinds_init interactive \
  --requires shell-configured \
  --provides keybinds-ready

# Noninteractive-only: lightweight PATH setup for scripts
zdot_register_hook _env_noninteractive noninteractive \
  --requires bootstrap-ready \
  --provides env-ready
```

`zdot_define_module` takes this further by letting a single module declare
separate interactive and noninteractive init functions:

```zsh
zdot_define_module nodejs \
  --configure _nodejs_configure \
  --load-plugins "nvm-sh/nvm" \
  --interactive-init _nodejs_interactive_init \
  --noninteractive-init _nodejs_noninteractive_init
```

The framework sorts each context's hooks independently, so the interactive
plan can defer heavy work while the noninteractive plan runs lean and fast.

## One file, two contexts: using `.zshrc` as `.zshenv`

A common dotfiles pattern is to symlink `.zshenv` to the same file as `.zshrc`.
Since Zsh always sources `.zshenv` (even for non-interactive shells), this gives
every shell -- scripts, `ssh host command`, cron jobs -- access to your `PATH`,
environment variables, and tool setup without maintaining two separate files.

The problem: if you open a terminal, Zsh sources `.zshenv` first and then
`.zshrc`. Same file, sourced twice. Without protection, everything runs twice.

zdot handles this with a **double-source guard** in `zdot_init`:

```zsh
zdot_init() {
    (( _ZDOT_INIT_DONE )) && return 0   # already ran? do nothing
    _ZDOT_INIT_DONE=1
    # ... clone, plan, execute, compile
}
```

Additionally, `zdot_register_hook` deduplicates by name -- if a module file is
sourced twice, the second registration is silently skipped. Between these two
guards, the file can be sourced any number of times safely.

### The ordering problem: `.zshenv` runs before `/etc/zprofile`

zdot's re-entry guard is sufficient to prevent double execution, but there is a
subtler issue with running the full interactive setup at `.zshenv` time.

Zsh's startup file order for an interactive login shell is:

```
/etc/zshenv  →  ~/.zshenv
/etc/zprofile  →  ~/.zprofile
/etc/zshrc  →  ~/.zshrc
```

System files like `/etc/zprofile` run **between** `.zshenv` and `.zshrc`. On
macOS, `/etc/zprofile` calls `/usr/libexec/path_helper` to set up the base
`PATH` (including Homebrew's prefix). If your interactive setup -- and zdot's
`brew` module -- runs at `.zshenv` time, it executes before `path_helper` has
had a chance to run, so `brew` may not be on `PATH` yet.

The zdot guard solves double-execution but does not help here: once interactive
init has run at `.zshenv` time, the `.zshrc` source is a no-op and
`/etc/zprofile`'s additions arrive too late.

### Recommended pattern: defer interactive init to `.zshrc`

Add this guard **before** the zdot boilerplate in your shared `.zshrc`/`.zshenv`
file:

```zsh
# When interactive, only initialize from .zshrc — not .zshenv.
# This lets /etc/zprofile (Homebrew PATH, path_helper, etc.) run first.
[[ -o interactive ]] && [[ "${${(%):-%x}:t}" == ".zshenv" ]] && return
```

`${(%):-%x}` is zsh's prompt-expansion equivalent of `BASH_SOURCE[0]`: it
expands to the name of the file currently being read. Combined with `:t` (tail /
basename), it returns `.zshenv` or `.zshrc` depending on which symlink zsh
opened.

With this guard in place:

- **Interactive shell, sourced as `.zshenv`** — returns immediately; waits for
  `.zshrc` to trigger zdot.
- **Interactive shell, sourced as `.zshrc`** — runs the full interactive setup,
  after `/etc/zprofile` has already executed.
- **Non-interactive shell, sourced as `.zshenv`** — `-o interactive` is false,
  guard is skipped, zdot runs the noninteractive plan as normal.

### Putting it together

```zsh
# This file is both ~/.zshenv AND ~/.zshrc (via symlink).

# Interactive shells: wait for .zshrc so /etc/zprofile runs first.
[[ -o interactive ]] && [[ "${${(%):-%x}:t}" == ".zshenv" ]] && return

# Run-once guard (defensive; zdot_init is also internally guarded).
[[ -n "$_ZDOT_INITIALIZED" ]] && return
_ZDOT_INITIALIZED=1

source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

# Modules register hooks for specific contexts internally.
# Loading a module does NOT execute it -- it just registers hooks.
zdot_load_module xdg           # provides xdg-configured (all contexts)
zdot_load_module bootstrap     # provides bootstrap-ready: the default baseline (all contexts)
zdot_load_module env           # sets PATH, LANG, etc. (all contexts)
zdot_load_module brew          # homebrew (all contexts)
zdot_load_module history       # history options (all contexts)
zdot_load_module secrets       # 1Password (all contexts)
zdot_load_module nodejs        # nvm (interactive: deferred; noninteractive: eager)
zdot_load_module fzf           # fuzzy finder (interactive only)
zdot_load_module keybinds      # ZLE key bindings (interactive only)
zdot_load_module plugins       # third-party plugins (interactive only)
zdot_load_module omz           # Oh-My-Zsh bundle defaults
zdot_load_module starship-prompt  # prompt theme (interactive only)
zdot_load_module completions   # tab completion (interactive only)
zdot_load_module local_rc      # ~/.zshenv_local (early, in bootstrap) + ~/.zshrc_local (late)

zdot_init
```

When sourced as `.zshenv` (noninteractive, e.g. a script):
- Guard passes (not interactive).
- Context: `noninteractive nonlogin`.
- Only hooks registered for `noninteractive` run: `PATH` setup, environment
  variables, tool availability. Interactive-only modules are skipped entirely.

When sourced as `.zshenv` for an interactive shell:
- Guard fires; file returns immediately.
- `/etc/zprofile` (Homebrew, `path_helper`) runs next.
- Then `.zshrc` is sourced and zdot runs the full interactive plan with a
  correctly populated `PATH`.

When sourced as `.zshrc` (interactive):
- Guard passes (filename is `.zshrc`).
- `_ZDOT_INITIALIZED` not yet set; full init proceeds.
- On subsequent subshells that re-source `.zshrc`, the run-once guard fires.

## Variants

Contexts describe *how* the shell was started. Variants describe *where* --
a user-defined label that lets different hooks run on different machines without
maintaining separate config files.

Set the variant in any of three ways (checked in priority order):

```zsh
# 1. Environment variable (highest priority)
export ZDOT_VARIANT=work

# 2. zstyle
zstyle ':zdot:variant' name work

# 3. Detection function (dynamic, per-machine)
zdot_detect_variant() {
  case $HOST in
    (work-*)  REPLY=work  ;;
    (pi-*)    REPLY=small ;;
    (*)       REPLY=""    ;;    # default variant
  esac
}
```

Use `--variant` and `--variant-exclude` on hooks to control which machines
they activate on:

```zsh
# Only on work machines:
zdot_register_hook _vpn_init interactive \
  --variant work \
  --requires brew-ready \
  --provides vpn-ready

# Everywhere except resource-constrained machines:
zdot_register_hook _heavy_completions_init interactive \
  --variant-exclude small \
  --requires plugins-loaded \
  --provides completions-ready
```

Both flags also work on `zdot_define_module` (applying to all of a module's
phases) and `zdot_simple_hook`. `--variant` may repeat for OR logic;
`--variant` and `--variant-exclude` are mutually exclusive per call.

Hooks with no `--variant` flag run in all variants (backward compatible).
The variant becomes part of the execution plan's cache key, so switching
variants just means rebuilding the plan on next shell start.

In `.zshrc`, `zdot_is_variant` lets module *selection* vary too:

```zsh
if zdot_is_variant work; then
  zdot_load_module corporate-proxy
fi
```

## Controlling deferred execution

zdot splits the execution plan into an **eager** pass (runs before the first
prompt) and a **deferred** pass (runs just after it, via `zsh-defer`), so the
prompt appears instantly while heavy setup finishes in the background.

A hook lands in the deferred set in one of two ways:

- **Explicitly** -- registered with `--deferred` (or `--deferred-prompt`,
  which refreshes the prompt afterward). `zdot_define_module`'s `--post-init`
  and `--interactive-init` phases are deferred by default.
- **By force-deferral** -- a non-deferred hook whose required phase is only
  provided by a deferred hook cannot run eagerly, so zdot promotes it into
  the deferred set. This propagates transitively along the dependency chain.

Force-deferral emits a warning, because it usually means more is deferred
than the author expected. When it's intentional, acknowledge it in `.zshrc`:

```zsh
zdot_allow_defer _fzf_post_plugin          # accept for all phases
zdot_allow_defer _nodejs_init nodejs-configured   # accept for one phase
```

When deferred hooks need a relative order that isn't expressed by
`--requires`/`--provides`, impose one from the outside:

```zsh
zdot_defer_order fzf shell-extras autocompletion
# fzf before shell-extras before autocompletion
```

(`--after`/`--before` on the hook itself are the declarative alternative --
see the [API reference](api-reference.md#zdot_defer_order) for when to use
which.)

Ad-hoc commands can join the deferred phase too:

```zsh
zdot_defer eval "$(pyenv init -)"          # run after the first prompt
zdot_defer_until 2 zdot_cache_compile_all  # run 2 seconds after startup
```

Two predefined groups bracket the deferred phase: `pre-defer` members run as
the last eager step, and `finally` members run after *everything*, deferred
work included -- see
[Predefined groups](module-guide.md#predefined-groups-bootstrap-pre-defer-and-finally).
Inspect what's queued with `zdot hook defer-queue`, and the scheduling
internals are in
[Implementation](implementation.md#force-deferral-propagation).

## Writing a bundle handler

A **bundle** is a plugin-framework handler that owns a family of plugin specs
-- the shipped `omz` handler claims `omz:*`, the `pz` handler claims `pz:*`.
Registering your own handler teaches the plugin system a new spec prefix:
how to clone the framework, resolve a spec to a path, and load it.

Every handler implements exactly four functions, each taking a single
`<spec>` argument:

```zsh
zdot_bundle_<name>_match <spec>   # Return 0 if this handler owns spec
zdot_bundle_<name>_path  <spec>   # Print the filesystem path for spec
zdot_bundle_<name>_clone <spec>   # Ensure the plugin is on disk (may be a no-op)
zdot_bundle_<name>_load  <spec>   # Source / activate the plugin
```

All four are required. If a handler does not need cloning (e.g. the framework
is cloned once at init time), `zdot_bundle_<name>_clone` must still be
defined as a no-op.

Optionally, a handler may define an init function that `zdot_init` calls
during its bundle-init pass, **before** any plugins are cloned or loaded:

```zsh
zdot_bundle_<name>_init() {
    # one-time setup: set environment vars, configure paths, etc.
}
```

Registration must come **after** all the functions are defined, at the end of
the file, declaring the init function and the phase it provides (if any):

```zsh
zdot_register_bundle <name> [--init-fn zdot_bundle_<name>_init] [--provides <phase>]
```

`zdot_register_bundle` is idempotent -- sourcing the file twice is safe. The
`--provides` phase is what makes
[`--auto-bundle-deps`](module-guide.md#bundle-framework-integration-omz-prezto)
work for your prefix: modules loading `<name>:` specs automatically gain a
`--requires` on that phase, so framework plugins can't load before the
framework itself.

A complete skeleton:

```zsh
# my-bundle.zsh — handler for "my:" specs

zdot_bundle_my_match() {
    [[ $1 == my:* ]]
}

zdot_bundle_my_path() {
    local spec=$1
    # derive and print the on-disk path for $spec
}

zdot_bundle_my_clone() {
    local spec=$1
    # clone / install if not present; or leave empty if not needed
}

zdot_bundle_my_load() {
    local spec=$1
    # source the plugin entry point
}

zdot_bundle_my_init() {
    # one-time framework setup
}

zdot_register_bundle my --init-fn zdot_bundle_my_init --provides my-bundle-initialized
```

Handler files ship in `core/plugin-bundles/` and are sourced explicitly from
`zdot.zsh`; a user-supplied handler can simply be sourced from a module or
`.zshrc` before `zdot_init`. The registry mechanics (state arrays, dispatch
order, how `zdot_use_bundle` marks framework repos as non-orphaned) are
covered in [plugin-implementation.md](plugin-implementation.md).
