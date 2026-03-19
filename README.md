
![](docs/images/zdot.png)

# zdot - Modular Zsh Configuration Framework

zdot is a hook-based, dependency-aware configuration system for Zsh that
organizes your shell environment into modular, reusable components with
automatic dependency resolution.

---

- [Why zdot?](#why-zdot)
- [Quick Start](#quick-start)
  - [Option A: Standalone](#option-a-standalone-no-dotfiler)
  - [Option B: With dotfiler (recommended)](#option-b-with-dotfiler-recommended)
- [A Realistic `.zshrc`](#a-realistic-zshrc)
- [Directory Structure](#directory-structure)
- [Modules](#modules)
  - [Built-in Modules](#built-in-modules)
  - [Module Search Path](#module-search-path)
  - [Writing Modules](#writing-modules)
- [Contexts and Variants](#contexts-and-variants)
  - [Shell contexts](#shell-contexts)
  - [One file, two contexts: using `.zshrc` as `.zshenv`](#one-file-two-contexts-using-zshrc-as-zshenv)
  - [Variants](#variants)
- [CLI](#cli)
- [Debugging](#debugging)
- [Day-to-Day](#day-to-day)
- [Further Reading](#further-reading)

---

## Why zdot?

Traditional plugin managers load everything in a single pass. As your shell
config grows -- secrets from 1Password, lazy-loaded `nvm`, ssh via 1Password
agent, brew-installed tools -- you end up with implicit ordering dependencies
scattered across one big `.zshrc`. Miss one and things break silently.

zdot fixes this:

- **Declare, don't order.** Each module says what it *provides* (`brew-ready`)
  and what it *requires* (`xdg-configured`). zdot topologically sorts the rest.
- **Modular by design.** One directory per concern. Swap, override, or skip
  modules without touching anything else.
- **Fast.** Execution plans are cached. All startup code is compiled to `.zwc`
  bytecode. Deferred loading via `zsh-defer` keeps the prompt instant.
- **Plugin management built in.** Clone, load, and compile plugins from GitHub,
  Oh-My-Zsh, or Prezto -- integrated into the same dependency graph.
- **Context-aware.** Different hooks for interactive vs non-interactive, login
  vs non-login, and user-defined variants (e.g. `work` vs `home`).

## Quick Start

### Option A: Standalone (no dotfiler)

```zsh
# 1. Clone zdot into your XDG config
git clone https://github.com/georgeharker/zdot \
  "${XDG_CONFIG_HOME:-$HOME/.config}/zdot"

# 2. Add to your ~/.zshrc (or ${XDG_CONFIG_HOME}/zsh/.zshrc):
source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

zdot_load_module xdg
zdot_load_module shell
zdot_load_module brew          # macOS only; skipped if brew not found
zdot_load_module keybinds
zdot_load_module completions

zdot_init

# 3. Restart your shell
exec zsh
```

That's it. `zdot_init` resolves dependencies, builds the execution plan, runs
everything in the right order, and compiles to bytecode for next time.

### Option B: With dotfiler (recommended)

[dotfiler](https://github.com/georgeharker/dotfiler) is a dotfiles manager
that keeps your config repo in sync across machines. Together with zdot it
forms a layered system: dotfiler manages the repo and symlink tree, zdot
manages the Zsh configuration inside it.

Neither tool requires the other -- each works independently. But when used
together, dotfiler handles updating zdot as a registered component.

#### What you end up with

```
~/.dotfiles/                         # your dotfiles git repo
  .config/
    zdot/                            # zdot (git submodule)
    dotfiler/
      hooks/
        zdot.zsh -> ../../zdot/core/dotfiler-hook.zsh
    zsh/
      .zshrc                         # your zshrc, managed by dotfiler

~/.config/                           # linktree (symlinks into ~/.dotfiles)
  zdot/  -> ~/.dotfiles/.config/zdot/
  zsh/   -> ~/.dotfiles/.config/zsh/
```

#### Step 1 -- Create your dotfiles repo

```zsh
mkdir -p ~/.dotfiles && cd ~/.dotfiles && git init
```

#### Step 2 -- Install dotfiler

```zsh
git clone https://github.com/georgeharker/dotfiler ~/.dotfiles/.nounpack/dotfiler
export PATH="$HOME/.dotfiles/.nounpack/dotfiler:$PATH"
```

#### Step 3 -- Add zdot as a submodule

```zsh
cd ~/.dotfiles
git submodule add https://github.com/georgeharker/zdot .config/zdot
git submodule update --init --recursive
```

#### Step 4 -- Create a minimal `.zshrc`

Create `~/.dotfiles/.config/zsh/.zshrc`:

```zsh
source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

zdot_load_module xdg
zdot_load_module shell
zdot_load_module brew         # macOS only
zdot_load_module completions

zdot_init
```

Commit:

```zsh
cd ~/.dotfiles
git add .config/zsh/.zshrc && git commit -m "add initial zshrc"
```

#### Step 5 -- Register the zdot hook and unpack

```zsh
dotfiler setup --bootstrap-hook ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh -u
```

This creates the dotfiler hook symlink and unpacks the linktree into
`~/.config/`. After this step your shell is live.

#### Step 6 -- Enable self-updates (optional)

Add to your `.zshrc` before `zdot_init`:

```zsh
zstyle ':zdot:update' mode prompt    # ask before updating at shell start
zstyle ':dotfiler:update' in-tree-commit auto  # auto-commit submodule pins
```

#### Step 7 -- Start a new shell

```zsh
exec zsh
```

#### Bootstrap on a new machine

Once your dotfiles repo is on a remote:

```zsh
# 1. Clone dotfiler
git clone https://github.com/georgeharker/dotfiler ~/.dotfiles/.nounpack/dotfiler
export PATH="$HOME/.dotfiles/.nounpack/dotfiler:$PATH"

# 2. Clone your dotfiles
git clone <your-repo-url> ~/.dotfiles
git -C ~/.dotfiles submodule update --init --recursive

# 3. Bootstrap (reads hooks from repo, unpacks linktree)
dotfiler setup --bootstrap
```

See [dotfiler's zdot integration docs](https://github.com/georgeharker/dotfiler/blob/main/docs/zdot-integration.md)
for the complete reference.

## A Realistic `.zshrc`

Here's a more complete example showing modules, plugins, deferred loading,
and variants:

```zsh
source "${XDG_CONFIG_HOME}/zdot/zdot.zsh"

# ── Configuration ──────────────────────────────────────
zstyle ':zdot:update' mode prompt
zstyle ':zdot:cache'  enabled true

# ── Modules ────────────────────────────────────────────
zdot_load_module xdg
zdot_load_module env
zdot_load_module shell
zdot_load_module brew
zdot_load_module secrets          # 1Password secrets
zdot_load_module nodejs           # nvm + node
zdot_load_module rust
zdot_load_module fzf
zdot_load_module keybinds
zdot_load_module plugins          # third-party zsh plugins
zdot_load_module shell-extras     # git, eza, ssh plugins
zdot_load_module completions
zdot_load_module starship-prompt
zdot_load_module local_rc         # source ~/.zshrc.local if it exists

# ── Defer control ──────────────────────────────────────
# Acknowledge these hooks will be force-deferred
zdot_allow_defer _nodejs_init nodejs-configured
zdot_allow_defer _completions_init

# ── Go ─────────────────────────────────────────────────
zdot_init
```

## Directory Structure

```
zdot/
├── zdot.zsh              # Main entry point (source this)
├── core/                 # Framework internals (do not modify)
│   ├── hooks.zsh         # Hook registration & dependency resolution
│   ├── modules.zsh       # Module search path & loading
│   ├── plugins.zsh       # Plugin manager (clone/load/defer)
│   ├── init.zsh          # zdot_init() orchestration
│   ├── cache.zsh         # Bytecode compilation & plan caching
│   ├── ctx.zsh           # Context & variant detection
│   ├── logging.zsh       # Logging functions
│   ├── functions.zsh     # Function autoloading
│   ├── completions.zsh   # Completion registration
│   ├── utils.zsh         # Platform detection & utilities
│   ├── compinit.zsh      # Shared compinit machinery
│   ├── update.zsh        # Self-update integration
│   ├── functions/        # Autoloaded CLI functions
│   └── plugin-bundles/   # OMZ & Prezto bundle handlers
├── modules/              # Built-in modules (26)
│   ├── xdg/
│   ├── brew/
│   ├── shell/
│   ├── fzf/
│   └── ...
├── docs/                 # Documentation
└── scripts/              # Benchmarking & profiling utilities
```

User modules live outside this tree (see [Module Search Path](#module-search-path)).

## Modules

A module is a directory containing a single `.zsh` file of the same name. When
loaded, it registers one or more hooks that declare what they provide and
require. zdot resolves the dependency graph and executes hooks in the correct
order.

### Built-in Modules

zdot ships with 26 built-in modules. See [docs/modules.md](docs/modules.md)
for the full reference.

| Module | Description |
|--------|-------------|
| `xdg` | XDG Base Directory setup |
| `brew` | Homebrew (macOS) |
| `shell` | Shell options, history, path |
| `secrets` | 1Password secrets management |
| `nodejs` | Node.js / nvm |
| `fzf` | Fuzzy finder + integrations |
| `plugins` | Third-party zsh plugins |
| `completions` | Completion file generation |
| `starship-prompt` | Starship prompt |
| ... | [See all 26 modules](docs/modules.md) |

### Module Search Path

`zdot_load_module` searches directories in order -- user directories first, then
the built-in `modules/` directory. This lets you override any built-in module:

```zsh
zstyle ':zdot:modules' search-path "${XDG_CONFIG_HOME}/zsh/modules"

# Now your modules/ dir is searched first
zdot_load_module brew    # loads yours if it exists, falls back to built-in
```

### Writing Modules

The simplest module:

```zsh
# modules/mymodule/mymodule.zsh

_mymodule_init() {
  export MY_VAR="hello"
}

zdot_simple_hook mymodule
# Registers _mymodule_init with:
#   requires: xdg-configured
#   provides: mymodule-configured
#   context:  interactive noninteractive
```

For complex modules with plugin loading, multi-phase lifecycles, and bundle
integration, see the [Module Writer's Guide](docs/module-guide.md).

## Contexts and Variants

### Shell contexts

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

#### Why this matters

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
  --requires xdg-configured \
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

### One file, two contexts: using `.zshrc` as `.zshenv`

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

#### Putting it together

```zsh
# This file is both ~/.zshenv AND ~/.zshrc (via symlink).
# zdot handles the rest.

source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

# Modules register hooks for specific contexts internally.
# Loading a module does NOT execute it -- it just registers hooks.
zdot_load_module xdg           # provides xdg-configured (all contexts)
zdot_load_module env           # sets PATH, LANG, etc. (all contexts)
zdot_load_module brew          # homebrew (all contexts)
zdot_load_module shell         # history, options (all contexts)
zdot_load_module secrets       # 1Password (all contexts)
zdot_load_module nodejs        # nvm (interactive: deferred; noninteractive: eager)
zdot_load_module fzf           # fuzzy finder (interactive only)
zdot_load_module keybinds      # ZLE key bindings (interactive only)
zdot_load_module plugins       # third-party plugins (interactive only)
zdot_load_module starship-prompt  # prompt theme (interactive only)
zdot_load_module completions   # tab completion (interactive only)
zdot_load_module local_rc      # source ~/.zshrc.local (interactive only)

zdot_init   # guarded -- safe to call from both .zshenv and .zshrc
```

When sourced as `.zshenv` (noninteractive):
- Context: `noninteractive nonlogin`
- Only hooks registered for `noninteractive` run: `PATH` setup, environment
  variables, tool availability. Interactive-only modules like `fzf`, `keybinds`,
  and `starship-prompt` are skipped entirely.

When sourced again as `.zshrc` (interactive):
- `_ZDOT_INIT_DONE` is already set -- `zdot_init` returns immediately.
- Nothing runs twice. The first pass already executed the full interactive plan.

When sourced as `.zshenv` for an interactive login shell:
- Context: `interactive login`
- All interactive hooks run: plugins, prompts, keybinds, deferred loading.
- The `.zshrc` source is a no-op thanks to the guard.

### Variants

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

Hooks with no `--variant` flag run in all variants (backward compatible).
The variant becomes part of the execution plan's cache key, so switching
variants just means rebuilding the plan on next shell start.

## CLI

zdot provides an interactive CLI using a `<noun> <verb>` pattern with tab
completion:

```
zdot cache invalidate       # clear all caches
zdot cache stats            # show cache statistics
zdot hook list              # list registered hooks
zdot hook status            # show hook execution status
zdot plugin list            # list plugins
zdot plugin update <name>   # update a plugin
zdot module list            # list loaded modules
zdot info                   # environment info
zdot debug                  # debug diagnostics
zdot bench                  # startup benchmark
zdot profile                # zprof startup profile
```

See [docs/commands.md](docs/commands.md) for the full CLI reference.

## Debugging

```zsh
# Verbose mode -- shows module loading, hook registration, execution order
ZDOT_VERBOSE=1 zsh

# Debug mode -- even more detail
ZDOT_DEBUG=1 zsh

# Inspect registered hooks
zdot hook list --all

# Show the execution plan
zdot hook status

# Full diagnostics
zdot debug
```

## Day-to-Day

| Task | Command |
|------|---------|
| Pull updates (with dotfiler) | `dotfiler update` |
| Add a module | Add `zdot_load_module <name>` to `.zshrc`, then `exec zsh` |
| Clone a built-in to customize | `zdot module clone <name>` |
| Clear caches after manual changes | `zdot cache invalidate` |
| Check startup time | `zdot bench` |
| Profile startup | `zdot profile` |

## Further Reading

| Document | Description |
|----------|-------------|
| [docs/api-reference.md](docs/api-reference.md) | Complete public API reference -- all functions, flags, and examples |
| [docs/modules.md](docs/modules.md) | Reference for all 26 built-in modules |
| [docs/module-guide.md](docs/module-guide.md) | Module writer's guide -- from quick start to complex lifecycles |
| [docs/commands.md](docs/commands.md) | Full CLI reference for the `zdot` command |
| [docs/plugins.md](docs/plugins.md) | Plugin system overview and usage |
| [docs/zstyle-reference.md](docs/zstyle-reference.md) | Complete reference for all `zstyle` configuration options |
| [docs/implementation.md](docs/implementation.md) | Architecture and implementation details |
| [docs/plugin-implementation.md](docs/plugin-implementation.md) | Plugin system internals |
| [docs/caching-implementation.md](docs/caching-implementation.md) | Bytecode compilation and plan caching internals |
| [docs/compinit.md](docs/compinit.md) | Completion system (`compinit`) and compaudit controls |
