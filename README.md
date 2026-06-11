
![](docs/images/zdot.png)

# zdot - Modular Zsh Configuration Framework

zdot is a hook-based, dependency-aware configuration system for Zsh that
organizes your shell environment into modular, reusable components with
automatic dependency resolution.

---

- [Why zdot?](#why-zdot)
- [Quick Start](#quick-start)
  - [Option A: Standalone](#option-a-standalone)
  - [Option B: With dotfiler (recommended)](#option-b-with-dotfiler-recommended)
- [A Realistic `.zshrc`](#a-realistic-zshrc)
- [Directory Structure](#directory-structure)
- [Modules](#modules)
- [Contexts and Variants](#contexts-and-variants)
- [CLI](#cli)
- [Debugging](#debugging)
- [Day-to-Day](#day-to-day)
- [Documentation](#documentation)

---

## Why zdot?

Traditional plugin managers load everything in a single pass. As your shell
config grows -- secrets from 1Password, lazy-loaded `nvm`, ssh via 1Password
agent, brew-installed tools -- you end up with implicit ordering dependencies
scattered across one big `.zshrc`. Miss one and things break silently.

zdot fixes this:

- **Declare, don't order.** Each module says what it *provides* (`brew-ready`)
  and what it *requires* (`bootstrap-ready`). zdot topologically sorts the rest.
- **Modular by design.** One directory per concern. Swap, override, or skip
  modules without touching anything else.
- **Fast.** Execution plans are cached. All startup code is compiled to `.zwc`
  bytecode. Deferred loading via `zsh-defer` keeps the prompt instant.
- **Plugin management built in.** Clone, load, and compile plugins from GitHub,
  Oh-My-Zsh, or Prezto -- integrated into the same dependency graph.
- **Context-aware.** Different hooks for interactive vs non-interactive, login
  vs non-login, and user-defined variants (e.g. `work` vs `home`).

## Quick Start

There are two supported ways to run zdot, and both are first-class:

- **Standalone** -- clone zdot, source it from your existing `.zshrc`. Right
  choice if you already have a dotfiles manager (stow, chezmoi, yadm) or just
  want to try zdot.
- **With [dotfiler](https://github.com/georgeharker/dotfiler)** -- zdot lives
  inside a dotfiler-managed dotfiles repo. Recommended for a full setup; see
  [why below](#option-b-with-dotfiler-recommended).

### Option A: Standalone

```zsh
# 1. Clone zdot into your XDG config
git clone https://github.com/georgeharker/zdot \
  "${XDG_CONFIG_HOME:-$HOME/.config}/zdot"

# 2. Add to your ~/.zshrc (or ${XDG_CONFIG_HOME}/zsh/.zshrc):
source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

zdot_load_module xdg
zdot_load_module bootstrap
zdot_load_module env
zdot_load_module history
zdot_load_module brew          # macOS only; skipped if brew not found
zdot_load_module keybinds
zdot_load_module completions

zdot_init

# 3. Restart your shell
exec zsh
```

That's it. `zdot_init` resolves dependencies, builds the execution plan, runs
everything in the right order, and compiles to bytecode for next time.

Standalone zdot can keep itself updated too -- opt in with
`zstyle ':zdot:update' mode prompt` (see the
[zstyle reference](docs/zstyle-reference.md#self-update--zdotupdate)).

### Option B: With dotfiler (recommended)

[dotfiler](https://github.com/georgeharker/dotfiler) is a dotfiles manager
that keeps your config repo in sync across machines. Neither tool requires
the other -- but together they cover what each leaves out:

- **zdot organizes what's *inside* your `.zshrc`; it deliberately does not
  manage the rc files themselves.** Your `.zshrc`/`.zshenv`, the rest of
  `~/.config`, and your user modules still need to live somewhere versioned
  and reach every machine. dotfiler tracks them as symlinks into a single git
  repo -- edit `~/.zshrc` in place and the change is already staged for
  commit.
- **One update cycle for everything.** zdot registers as a dotfiler update
  hook, so a single login-time check updates your dotfiles, your rc files,
  *and* zdot together.
- **Pinned, reproducible versions.** As a git submodule, the exact zdot
  version is recorded in your dotfiles history, and by default only advances
  on tagged releases.
- **One-command machine bootstrap.** `dotfiler setup --bootstrap` restores rc
  files, symlinks, and zdot on a fresh machine.

The happy path, from nothing:

```zsh
mkdir -p ~/.dotfiles && cd ~/.dotfiles && git init
git clone https://github.com/georgeharker/dotfiler .nounpack/dotfiler
git submodule add https://github.com/georgeharker/zdot .config/zdot
```

Then follow the [dotfiler + zdot quickstart](docs/quickstart-dotfiler.md) --
it walks through the `.zshrc`, hook registration, unpacking the symlink tree,
and bootstrapping new machines.

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
zdot_load_module bootstrap
zdot_load_module env
zdot_load_module history
zdot_load_module brew
zdot_load_module secrets          # 1Password secrets
zdot_load_module nodejs           # nvm + node
zdot_load_module rust
zdot_load_module fzf
zdot_load_module keybinds
zdot_load_module plugins          # third-party zsh plugins
zdot_load_module omz              # Oh-My-Zsh bundle defaults
zdot_load_module shell-extras     # git, eza, ssh plugins
zdot_load_module completions
zdot_load_module starship-prompt
zdot_load_module local_rc         # source ~/.zshrc_local if it exists

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
├── modules/              # Built-in modules
│   ├── xdg/
│   ├── brew/
│   ├── fzf/
│   └── ...
├── docs/                 # Documentation
└── scripts/              # Benchmarking & profiling utilities
```

User modules live outside this tree (see [Modules](#modules)).

## Modules

A module is a directory containing a single `.zsh` file of the same name. When
loaded, it registers one or more hooks that declare what they provide and
require. zdot resolves the dependency graph and executes hooks in the correct
order.

zdot ships 30+ built-in modules covering the common concerns:

| Module | Description |
|--------|-------------|
| `xdg` | XDG Base Directory setup |
| `env` | Core environment variables |
| `history` | Zsh history (XDG location, per-directory history) |
| `brew` / `apt` | Package-manager PATH and tool verification |
| `secrets` | 1Password secrets management |
| `nodejs` | Node.js / nvm with lazy loading |
| `fzf` | Fuzzy finder + integrations |
| `plugins` | Third-party zsh plugins |
| `completions` | Completion file generation + compinit |
| `starship-prompt` | Starship prompt (also: `omp-prompt`, `omz-prompt`) |
| ... | [Full catalog](docs/modules.md) |

The simplest module is three lines:

```zsh
# ~/.config/zdot-modules/mymodule/mymodule.zsh

_mymodule_init() {
  export MY_VAR="hello"
}

zdot_simple_hook mymodule
```

Drop it in `~/.config/zdot-modules/` (searched automatically, ahead of the
built-in modules -- so a user module can also shadow and replace any built-in
of the same name) and add `zdot_load_module mymodule` to your `.zshrc`. The
[Module Writer's Guide](docs/module-guide.md) covers everything from here to
multi-phase plugin lifecycles, and `zdot module clone <name>` copies a
built-in module to your user directory as a starting point.

## Contexts and Variants

Zsh runs your startup files in different scenarios -- an interactive terminal,
a script run by `zsh -c`, a login shell over SSH. zdot models this with
**contexts**: every hook declares when it should run, and zdot filters the
execution plan accordingly.

| Context | Meaning | Example scenario |
|---------|---------|------------------|
| `interactive` | Shell attached to a user typing commands | `exec zsh`, opening a terminal |
| `noninteractive` | Shell running a command or script | `zsh -c '...'`, `ssh host command` |
| `login` | First shell in a session | `ssh host`, macOS Terminal.app |
| `nonlogin` | Not the session's first shell | Sub-shells, `zsh` inside tmux |

**Variants** add a third, user-defined dimension -- *where* the shell runs
(`work` vs `home` vs a resource-constrained Pi) -- so different hooks can
activate on different machines from one shared config.

Contexts also make it practical to use a single file as both `.zshenv` and
`.zshrc`, so scripts and `ssh host command` get your `PATH` without the
interactive overhead.

The full story -- per-context hook registration, the `.zshenv` symlink
pattern, and variant detection -- is in
[Advanced Usage](docs/advanced.md).

## CLI

zdot provides an interactive CLI using a `<noun> <verb>` pattern with tab
completion:

```
zdot cache status           # show cache statistics
zdot cache invalidate       # clear all caches
zdot hook list              # list registered hooks
zdot hook plan              # print the execution plan
zdot plugin list            # list plugins
zdot plugin update <name>   # update a plugin
zdot module list            # list loaded modules
zdot update check-updates   # check for zdot updates
zdot info                   # environment info
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

# Show the execution plan and per-hook status
zdot hook plan
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

## Documentation

The docs are organized as a journey -- start at the top, go as deep as you
need ([docs/README.md](docs/README.md) is the full index):

| Stage | Document |
|-------|----------|
| Install & first shell | [Quickstart: dotfiler + zdot](docs/quickstart-dotfiler.md) (standalone: [Quick Start](#quick-start) above) |
| Use plugins & configure shipped modules | [Using Plugins](docs/using-plugins.md) |
| Write your own modules | [Module Writer's Guide](docs/module-guide.md) |
| Contexts, variants, defer, bundles | [Advanced Usage](docs/advanced.md) |
| Reference | [API](docs/api-reference.md) · [zstyle options](docs/zstyle-reference.md) · [CLI](docs/commands.md) · [Module catalog](docs/modules.md) · [compinit](docs/compinit.md) |
| Internals | [Implementation](docs/implementation.md) · [Plugin internals](docs/plugin-implementation.md) |

## Acknowledgements

Linting throughout this codebase is checked with [shuck](https://github.com/ewhauser/shuck) — a fast shell linter with first-class zsh support. Thanks to the shuck project for catching the bugs that bash-targeted linters miss.
