
![](docs/images/zdot.png)

# zdot - Modular Zsh Configuration Framework

zdot is a hook-based, dependency-aware configuration system for Zsh that makes it easy to organize your shell environment into modular, reusable components.

## Table of Contents

- [Motivation](#motivation)
- [Overview](#overview)
- [Quick Start](#quick-start)
- [Creating Modules](#creating-modules)
- [Module Search Path](#module-search-path)
- [Core Functions Reference](#core-functions-reference)
- [Hook System](#hook-system)
- [Variants](#variants)
- [Debugging](#debugging)
- [Best Practices](#best-practices)
- [dotfiler Integration](#dotfiler-integration)

## Motivation

There are some fantastic, fast plugin managers out there - so why write another?

Over time, my shell config increased in complexity.  I found that the traditional plugin managers wanted to be a single invocation, but often you had to configure plugins prior to loading, then do something with them after they were loaded:

````
#!/bin/zsh

# Setup options
zstyle...
ENV_VAR=

# invoke plugin manager
antidote ...

# Use your plugins
````

Already the logic for using a plugin was split into three places - init, load and use.

As I tried to do more in my shell setup - bring in and set up shell secrets with onepassword, manage late-loading for `nvm` which is slow, ensure ssh uses onepassword... I found that there were interdependencies between plugin uses and between sections of my `.zshrc` and those became hard to manage, and were implicit in terms of the ordering in the file.

Eventually this felt fragile.


````
#!/bin/zsh

# Setup options
zstyle...
ENV_VAR=

# setup brew paths          -----
                                 |
# invoke plugin manager          |
antidote ...                <----|
                                 |
function uses_brew() {      <----

}

# Use your plugins
````

more-over, perhaps some other function relies on the op secrets functions etc.. etc..

Things that didn't work well:

- single location for loading all plugins
- init logic separate from usage logic
- no clear dependencies between parts of init scripts
- plugins often comment (needs to be after), but plugins themselves also have no dependency chain
- zsh-defer for delayed prompt etc submits in order which may not be ideal run order

What did work

- compilation of plugins to zwc bytecode
- cloning and pulling of plugins
- handles simpler setups reasonably

## What zdot offers

if rc / init files are structured as a list of functions, rather than a simple list of commands to run, then we can invoke those functions in a specified order.

Zdot works out what that order should be, saves it and then invokes that order on startup.  It's smart about when to invalidate the cached ordering.  Any of your modules change and it will invalidate the cache, but the usual startup is fast.

Zdot also precompiles all of your startup code to .zwc.

Zdot also helps manage plugins - either from omz, prezto or another source.  It can clone, manage and help source those plugins.  This portion of functionality overlaps with that provided by a traditional plugin manager like `antidote` / `Antigen` / `zinit` / `sheldon` (or others).

## Is it better than (pick a plugin manager)

Whilst zdot does manage plugins, it aims to be a bit more than that, offering a way to structure user setup modularly, integrating plugin management as part of your setup.  It doesn't aim to load all plugins at once, so you can customize what loads when and under what circumstances.

Better?  Just Different. I've done some benchmarking and comparable setups are within comparable timeframes. Zdot appears performant in the comparisons - and whilst absolute best startup speed wasn't the goal, it should be fast enough (or with delayed loading features, faster) than the fastest of the plugin managers.

## Overview

### Key Features

- **Modular Architecture**: Split your configuration into logical modules (brew, ssh, completions, etc.)
- **User Modules**: Extend or override built-in modules without touching the core library
- **Dependency Management**: Hooks automatically execute in the correct order based on their dependencies
- **Context Awareness**: Different configurations for interactive/non-interactive and login/non-login shells
- **Optional Loading**: Modules can gracefully handle missing dependencies (e.g., if homebrew isn't installed)
- **Debug Tools**: Built-in tools to inspect module loading and hook execution

### Architecture

zdot uses a **hook-based system** where each module registers functions (hooks) that:
1. Declare what phase they **provide** (e.g., "brew-ready", "ssh-configured")
2. Declare what phases they **require** (dependencies on other modules)
3. Specify which shell **contexts** they should run in (interactive, login, etc.)

The system automatically:
- Builds an execution plan that respects all dependencies
- Skips modules when dependencies are missing (if marked optional)
- Runs hooks in the correct order during shell initialization

## Quick Start

### Directory Structure

```
~/.dotfiles/.config/zsh/zdot/
├── zdot.zsh              # Main entry point (source this in .zshrc)
├── core/                 # Core system (don't modify)
│   ├── hooks.zsh         # Hook registration & execution
│   ├── logging.zsh       # Logging functions
│   ├── utils.zsh         # Utility functions
│   └── functions/        # Autoloaded functions
├── lib/                  # Built-in modules
│   ├── brew/
│   ├── ssh/
│   ├── completions/
│   └── ...
└── config/               # Static configuration files
```

User modules live in directories you control, outside the core `lib/` tree (see [Module Search Path](#module-search-path)).

### Basic Usage in .zshrc

```zsh
# Source the zdot system
source "${ZDOTDIR:-$HOME/.config/zsh}/zdot/zdot.zsh"

# Load all modules from lib/ directory
zdot_load_modules

# Build execution plan from registered hooks
zdot_build_execution_plan

# Execute all hooks in dependency order
zdot_execute_all
```

## Creating Modules

### Module Structure

Each module lives in `lib/<module-name>/` and contains:

```
lib/mymodule/
├── mymodule.zsh          # Main module file (required)
├── config/               # Configuration files (optional)
│   └── settings.conf
└── functions/            # Helper functions (optional)
    └── _mymodule_helper
```

### Basic Module Template

Create `lib/mymodule/mymodule.zsh`:

```zsh
# Prevent double-loading
[[ -n "${_MYMODULE_LOADED:-}" ]] && return 0
_MYMODULE_LOADED=1

# Module initialization function
_mymodule_init() {
    # Check if module's dependencies are available
    if ! command -v sometool &>/dev/null; then
        zdot_verbose "mymodule: sometool not found, skipping"
        return 1
    fi

    # Do your initialization
    export MYMODULE_PATH="/path/to/config"
    source "${MYMODULE_PATH}/config.zsh"

    zdot_success "mymodule initialized"
    return 0
}

# Register the hook
zdot_register_hook _mymodule_init interactive noninteractive \
    --provides mymodule-ready \
    --optional
```

### Advanced Module with Dependencies

```zsh
[[ -n "${_MYMODULE_LOADED:-}" ]] && return 0
_MYMODULE_LOADED=1

_mymodule_init() {
    # This runs after xdg-configured and brew-ready phases
    
    local config_dir="${XDG_CONFIG_HOME}/mymodule"
    
    if [[ ! -d "$config_dir" ]]; then
        zdot_warn "mymodule: config directory not found"
        return 1
    fi
    
    # Use homebrew-installed tool
    if command -v homebrew-tool &>/dev/null; then
        eval "$(homebrew-tool init)"
    fi
    
    zdot_success "mymodule configured"
    return 0
}

# Register with dependencies
zdot_register_hook _mymodule_init interactive noninteractive \
    --requires xdg-configured brew-ready \
    --provides mymodule-ready \
    --optional
```

## Module Search Path

`zdot_load_module` resolves module names against an ordered list of directories.
User-supplied directories are searched first; `lib/` is always the final fallback.
This means a module in your own directory shadows the built-in module of the same name.

### Setup

Add a `zstyle` before your `zdot_load_module` calls:

```zsh
zstyle ':zdot:modules' search-path ~/path/to/my-modules
```

Multiple paths are accepted (array):

```zsh
zstyle ':zdot:modules' search-path \
    "${XDG_CONFIG_HOME}/zsh/modules" \
    "${HOME}/.dotfiles/zsh-extra"
```

The path list is built once on first use. `lib/` is always appended last.

### Module structure

Identical to built-in modules — one directory per module, main file named the same
as the directory:

```
~/my-modules/
└── mymodule/
    └── mymodule.zsh     # Main module file
```

### Loading modules

```zsh
# In your .zshrc, before zdot_init:
zdot_load_module mymodule
```

The same call works for both built-in and user-supplied modules. The first directory
in the search path that contains `mymodule/mymodule.zsh` wins. All modules share a
single dedup registry, so each module is sourced at most once.

### Cloning a module as a starting point

```zsh
zdot module clone brew   # copies lib/brew/ into the first user directory in the search path
```

The destination must not already exist. Edit the copy freely — the original in `lib/` is untouched.

### CLI reference

| Command | Description |
|---|---|
| `zdot module list` | List all loaded modules and their source directory |
| `zdot module clone <name>` | Copy a module to the first user directory in the search path |

### Public API

| Function | Description |
|---|---|
| `zdot_load_module <name>` | Load a module (search path, dedup-safe) |
| `zdot_module_path <name>` | Return the path to a module's main file (sets `REPLY`) |
| `zdot_module_list` | Print all loaded modules with source directory |

---

## Core Functions Reference

### Hook Registration

#### `zdot_register_hook <function> [contexts...] [flags...]`

Register a function to be called during shell initialization.

**Arguments:**
- `function`: Function name to register (e.g., `_mymodule_init`)
- `contexts`: One or more of: `interactive`, `noninteractive`, `login`, `nonlogin`

**Flags:**
- `--requires phase1 phase2 ...`: Phases this hook depends on
- `--provides phase_name`: Phase this hook provides (enables other hooks to depend on it)
- `--optional`: Hook won't cause errors if requirements are missing

**Examples:**
```zsh
# Simple hook, no dependencies
zdot_register_hook _mymodule_init interactive --provides mymodule-ready

# Hook with dependencies
zdot_register_hook _mymodule_init interactive \
    --requires xdg-configured brew-ready \
    --provides mymodule-ready \
    --optional
```

### Sugar Functions

#### `zdot_simple_hook`

Convention-over-configuration helper for single-hook modules. Reduces the most common registration pattern to one line.

**Defaults:**
- Function: `_<name>_init` (must already exist)
- Requires: `xdg-configured`
- Provides: `<name>-configured`
- Contexts: `interactive noninteractive`

```zsh
# Simplest form — all defaults
zdot_simple_hook sudo

# Override provides token
zdot_simple_hook brew --provides brew-ready

# No auto-requires, interactive-only
zdot_simple_hook aliases --no-requires --context interactive

# Custom requires + optional dependency
zdot_simple_hook uv --requires secrets-loaded --optional

# Tool provider with multiple --provides-tool
zdot_simple_hook brew --provides brew-ready \
    --provides-tool op --provides-tool eza --provides-tool gh
```

All unrecognized flags are passed through to `zdot_register_hook`.

#### `zdot_define_module`

Multi-phase module definition for plugin-loading modules with configure → load → post-init lifecycles.

```zsh
# Simple plugin loader with auto-bundle detection
zdot_define_module tmux \
    --load-plugins omz:plugins/tmux \
    --auto-bundle

# Full lifecycle with explicit load function
zdot_define_module fzf \
    --configure _fzf_init \
    --load _fzf_plugins_load_omz \
    --post-init _fzf_post_plugin \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized \
    --provides-tool fzf

# With post-init customization
zdot_define_module autocomplete \
    --configure _autocomplete_plugins_configure \
    --load _autocomplete_plugins_load \
    --post-init _autocomplete_plugins_post_init \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized \
    --post-init-requires autosuggest-abbr-ready \
    --post-init-context interactive noninteractive
```

**Phase flags:** `--configure`, `--load`, `--load-plugins`, `--post-init`, `--interactive-init`, `--noninteractive-init`
**Modifier flags:** `--context`, `--configure-context`, `--load-context`, `--post-init-context`, `--post-init-requires`, `--provides-tool`, `--requires-tool`, `--requires`, `--auto-bundle`, `--group`

### Execution Control

#### `zdot_load_modules`

Automatically load all `.zsh` files from the `lib/` directory. Call this before building the execution plan.

#### `zdot_build_execution_plan`

Analyze all registered hooks and their dependencies, then create an ordered execution plan. Must be called after loading modules and before executing hooks.

#### `zdot_execute_all`

Execute all hooks in the planned order. Respects shell context and skips hooks whose requirements aren't met.

### Logging Functions

Always use these instead of `echo` for user-visible output:

```zsh
zdot_info "Informational message"        # Blue info icon
zdot_success "Operation succeeded"        # Green checkmark
zdot_warn "Warning message"               # Yellow warning icon
zdot_error "Error message"                # Red X icon
zdot_verbose "Debug details"              # Only shown with ZDOT_VERBOSE=1
```

**Note**: Do NOT replace `echo` statements that are function return values!

### Debugging Functions

#### `zdot_debug_info`

Show comprehensive debug information:
- Loaded modules
- All registered hooks organized by phase
- Hooks with missing requirements (errors)
- Completion system status

**Usage:**
```zsh
zdot_debug_info
```

#### `zdot_hooks_list [--all]`

List all registered hooks, organized by phase.

**Options:**
- `--all`: Show hooks for all contexts (default: only show active context)

**Usage:**
```zsh
zdot_hooks_list           # Show hooks for current context
zdot_hooks_list --all     # Show all hooks
```

## Hook System

### Understanding Phases

A **phase** is a named checkpoint in the initialization process. Modules provide phases, and other modules can require them.

**Common Phases:**
- `xdg-configured`: XDG directories are set up
- `brew-ready`: Homebrew is initialized
- `secrets-loaded`: Secret management (1Password) is ready
- `plugins-loaded`: Zsh plugins are loaded
- `shell-configured`: Shell options and settings are configured
- `finalize`: Cleanup phase (manually triggered)

### Dependency Resolution

zdot automatically orders hook execution based on dependencies:

```zsh
# This hook runs first (no dependencies)
zdot_register_hook _xdg_init interactive --provides xdg-configured

# This runs after xdg-configured
zdot_register_hook _brew_init interactive \
    --requires xdg-configured \
    --provides brew-ready

# This runs after both xdg-configured and brew-ready
zdot_register_hook _mymodule_init interactive \
    --requires xdg-configured brew-ready \
    --provides mymodule-ready
```

**Execution order:** `_xdg_init` → `_brew_init` → `_mymodule_init`

### Optional vs Required

**Optional hooks** (`--optional` flag):
- Won't cause errors if dependencies are missing
- Will be skipped if requirements aren't met
- Use for modules that depend on external tools (brew, docker, etc.)

**Required hooks** (no `--optional` flag):
- Will cause errors if dependencies are missing
- Use for critical system modules that must run

### Context Awareness

Hooks can specify which shell contexts they should run in:

**Contexts:**
- `interactive`: Interactive shells (your normal terminal)
- `noninteractive`: Scripts and non-interactive shells
- `login`: Login shells (first shell after login)
- `nonlogin`: Non-login shells (new terminal windows/tabs)

**Examples:**
```zsh
# Only interactive shells
zdot_register_hook _prompt_init interactive

# Both interactive and non-interactive
zdot_register_hook _env_init interactive noninteractive

# Only interactive login shells
zdot_register_hook _welcome_message interactive login
```

The system automatically detects the current context and only runs matching hooks.

## Variants

A **variant** is an optional third dimension of the context system — a user-defined label that lets you load different hooks on different machines or environments without maintaining separate config files.

**Examples:**
- `work` — load corporate VPN and extra tooling
- `small` — skip heavy tools on a low-power machine
- `home` — personal setup, no corporate modules

### Setting the Active Variant

Set the variant **before** `zdot_init` is called. zdot checks in this priority order:

```zsh
# Option A — environment variable (highest priority; set in .zshenv or a wrapper):
export ZDOT_VARIANT=work

# Option B — zstyle in .zshrc:
zstyle ':zdot:variant' name small

# Option C — detection function (most flexible):
zdot_detect_variant() {
    case $HOST in
        (macbook-pro)  REPLY=work  ;;
        (raspberry*)   REPLY=small ;;
        (*)            REPLY=""    ;;
    esac
}
```

If none of the above is set, the variant is empty — all hooks run as normal (backward compatible).

### Registering Variant-Constrained Hooks

Add `--variant` or `--variant-exclude` to any `zdot_register_hook` call:

```zsh
# Only run on the 'work' variant:
zdot_register_hook _vpn_init interactive noninteractive \
    --variant work \
    --requires brew-ready \
    --provides vpn-ready

# Run everywhere EXCEPT 'small':
zdot_register_hook _heavy_tools_init interactive \
    --variant-exclude small \
    --requires brew-ready

# Match any of several variants (multiple --variant flags):
zdot_register_hook _corp_tools_init interactive \
    --variant work --variant contractor \
    --requires brew-ready

# No --variant flag = runs in ALL variants (unchanged semantics):
zdot_register_hook _xdg_init interactive noninteractive \
    --provides xdg-configured
```

`--variant` and `--variant-exclude` are mutually exclusive on a single call.
The same flags are accepted by `zdot_simple_hook` and `zdot_define_module`
and are applied to every phase they register.

### Querying the Variant at Runtime

Use these inside hook bodies:

```zsh
zdot_variant          # prints active variant string (may be empty)
zdot_is_variant work  # returns 0 if active variant is 'work', 1 otherwise

_vpn_init() {
    zdot_is_variant work || return 0
    # work-specific setup...
}
```

### Notes

- **Backward compatible**: hooks with no `--variant` flag run in all variants including the empty default.
- **Cache-aware**: the plan cache key includes the variant (`interactive_nonlogin_work`, `interactive_nonlogin_default`, etc.). Each variant gets its own cache file.
- **Group barriers**: if all members of a `--group` are variant-excluded, the synthetic begin/end barriers are also excluded, so a `--requires-group` hook correctly sees its dependency as unsatisfied.

## Debugging

```zsh
export ZDOT_VERBOSE=1
source ~/.zshrc
```

This shows detailed information about:
- Module loading
- Hook registration
- Dependency resolution
- Execution order
- Skipped hooks and reasons

### Check Hook Registration

```zsh
zdot_hooks_list --all
```

Output shows:
- **Hooks by Phase**: Standard hooks organized by what they provide
- **⚠️  Hooks with Missing Requirements**: Configuration errors

### Inspect Execution Plan

After calling `zdot_build_execution_plan`, you can inspect the global array:

```zsh
# Show planned execution order
print -l "${_ZDOT_EXECUTION_PLAN[@]}"

# Show which hooks were executed
print -l "${(k)_ZDOT_HOOKS_EXECUTED[@]}"
```

### Debug Full Configuration

```zsh
zdot_debug_info
```

Shows complete system state including loaded modules, hooks, and completion status.

## Best Practices

### Module Organization

1. **One module per concern**: Don't mix ssh config with git config
2. **Use descriptive phase names**: `mymodule-ready` not `mymodule-done`
3. **Document dependencies**: Comment why you need each required phase
4. **Keep modules independent**: Minimize cross-module coupling

### Hook Registration

1. **Always use `--optional` for external dependencies**: Homebrew, Docker, etc. might not be installed
2. **Be specific with contexts**: Don't register in `noninteractive` unless necessary
3. **Return proper exit codes**: Return 1 on failure, 0 on success

### Error Handling

```zsh
_mymodule_init() {
    # Check for required tools
    if ! command -v required-tool &>/dev/null; then
        zdot_verbose "mymodule: required-tool not found"
        return 1  # Hook will be skipped
    fi
    
    # Try optional enhancement
    if command -v optional-tool &>/dev/null; then
        eval "$(optional-tool init)"
    fi
    
    # Always provide feedback
    zdot_success "mymodule initialized"
    return 0
}
```

### Performance

1. **Lazy load when possible**: Use autoloaded functions instead of sourcing everything
2. **Cache expensive operations**: Store results in variables
3. **Avoid unnecessary work in noninteractive shells**: Check context
4. **Use command substitution sparingly**: Forks are expensive

### Logging

1. **Use appropriate log levels**:
   - `zdot_verbose`: Debug details (only with ZDOT_VERBOSE=1)
   - `zdot_info`: Normal information
   - `zdot_success`: Successful operations
   - `zdot_warn`: Warnings that don't stop execution
   - `zdot_error`: Errors that prevent functionality

2. **Don't spam logs**: One success message per module is usually enough

3. **Make messages actionable**: Tell users what to do about errors

### Testing

Test your module in all relevant contexts:

```zsh
# Interactive shell
zsh -i

# Non-interactive shell
zsh -c 'source ~/.zshrc && zdot_debug_info'

# Login shell
zsh -l

# Non-login shell (default for new terminals)
zsh
```

## Examples

### Simple Module (No Dependencies)

`lib/aliases/aliases.zsh`:
```zsh
[[ -n "${_ALIASES_LOADED:-}" ]] && return 0
_ALIASES_LOADED=1

_aliases_init() {
    # General aliases
    alias ll='ls -lah'
    alias grep='grep --color=auto'
    
    # Git aliases
    alias gs='git status'
    alias gd='git diff'
    
    zdot_success "aliases loaded"
    return 0
}

zdot_register_hook _aliases_init interactive --provides aliases-loaded
```

### Module with External Dependency

`lib/docker/docker.zsh`:
```zsh
[[ -n "${_DOCKER_LOADED:-}" ]] && return 0
_DOCKER_LOADED=1

_docker_init() {
    if ! command -v docker &>/dev/null; then
        zdot_verbose "docker: command not found, skipping"
        return 1
    fi
    
    # Set Docker config location
    export DOCKER_CONFIG="${XDG_CONFIG_HOME}/docker"
    
    # Load completions if available
    if [[ -f "${DOCKER_CONFIG}/completions/zsh/_docker" ]]; then
        fpath=("${DOCKER_CONFIG}/completions/zsh" $fpath)
    fi
    
    zdot_success "docker configured"
    return 0
}

zdot_register_hook _docker_init interactive noninteractive \
    --requires xdg-configured \
    --provides docker-ready \
    --optional
```

### Module with Cleanup Hook

`lib/tempfiles/tempfiles.zsh`:
```zsh
[[ -n "${_TEMPFILES_LOADED:-}" ]] && return 0
_TEMPFILES_LOADED=1

_tempfiles_init() {
    # Create temp directory for this session
    export ZDOT_TEMP_DIR="${TMPDIR:-/tmp}/zdot-$$"
    mkdir -p "$ZDOT_TEMP_DIR"
    
    zdot_success "temp directory created: $ZDOT_TEMP_DIR"
    return 0
}

_tempfiles_cleanup() {
    if [[ -d "$ZDOT_TEMP_DIR" ]]; then
        zdot_info "Cleaning up temp directory: $ZDOT_TEMP_DIR"
        rm -rf "$ZDOT_TEMP_DIR"
        zdot_success "temp directory cleaned up"
    fi
    return 0
}

zdot_register_hook _tempfiles_init interactive noninteractive \
    --provides tempfiles-ready
```

### Complex Module with Multiple Hooks

`lib/python/python.zsh`:
```zsh
[[ -n "${_PYTHON_LOADED:-}" ]] && return 0
_PYTHON_LOADED=1

_python_env_init() {
    # Set up Python environment variables
    export PYTHONSTARTUP="${XDG_CONFIG_HOME}/python/pythonrc"
    export PYTHONPYCACHEPREFIX="${XDG_CACHE_HOME}/python"
    export PYTHONUSERBASE="${XDG_DATA_HOME}/python"
    
    return 0
}

_python_tools_init() {
    # Initialize Python version managers and tools
    if command -v pyenv &>/dev/null; then
        eval "$(pyenv init -)"
        zdot_verbose "python: pyenv initialized"
    fi
    
    if command -v poetry &>/dev/null; then
        export POETRY_CONFIG_DIR="${XDG_CONFIG_HOME}/poetry"
        zdot_verbose "python: poetry configured"
    fi
    
    zdot_success "python tools initialized"
    return 0
}

# First hook sets up environment
zdot_register_hook _python_env_init interactive noninteractive \
    --requires xdg-configured \
    --provides python-env-ready

# Second hook initializes tools (depends on environment)
zdot_register_hook _python_tools_init interactive \
    --requires python-env-ready \
    --provides python-ready \
    --optional
```

---

## dotfiler Integration

zdot is designed to work alongside
[dotfiler](https://github.com/georgeharker/dotfiler), a dotfiles manager that
keeps your config repo in sync across machines. Together they form a layered
system: dotfiler manages the repo and symlink tree, zdot manages the zsh
configuration inside it.

zdot is not required by dotfiler, and dotfiler is not required by zdot. Each
works independently. When used together, dotfiler handles updating zdot
itself as a registered component.

### Overview

- zdot lives inside your dotfiles repo as a submodule, subtree, or plain
  directory (submodule is recommended).
- A hook file (`core/dotfiler-hook.zsh`) registers zdot with dotfiler's update
  system. dotfiler discovers this file via a symlink in
  `$XDG_CONFIG_HOME/dotfiler/hooks/`.
- On every `dotfiler update` or auto-update-at-login, dotfiler pulls both the
  main dotfiles repo and zdot, then unpacks any changed files.

### First-Time Setup

#### Step 1: Add zdot to your dotfiles repo

**Submodule (recommended):**
```zsh
cd ~/.dotfiles
git submodule add https://github.com/georgeharker/zdot .config/zdot
git submodule update --init --recursive
```

**Subtree:**
```zsh
cd ~/.dotfiles
git subtree add --prefix=.config/zdot \
    https://github.com/georgeharker/zdot main --squash
```

#### Step 2: Install the dotfiler hook symlink

```zsh
dotfiler setup --bootstrap-hook ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh
```

This creates `$DOTFILES/.config/dotfiler/hooks/zdot.zsh` as a relative symlink
into the zdot tree and commits it to the dotfiles repo (you will be prompted to
confirm). Use `--yes` to skip the prompt.

#### Step 3: Unpack everything

```zsh
dotfiler setup -u
```

This unpacks the main dotfiles tree and all registered hook components
(including zdot) into your home directory. After this, the hook symlink at
`~/.config/dotfiler/hooks/zdot.zsh` is in place and dotfiler will manage
zdot going forward.

Steps 2 and 3 can be combined:
```zsh
dotfiler setup --bootstrap-hook ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh -u
```

### Bootstrap: New Machine

On a fresh machine with your dotfiles repo already cloned:

```zsh
# 1. Clone your dotfiles repo
git clone <your-dotfiles-repo> ~/.dotfiles

# 2. Initialise submodules (submodule topology only)
git -C ~/.dotfiles submodule update --init --recursive

# 3. Bootstrap — reads hooks directly from repo (linktree not yet set up)
dotfiler setup --bootstrap
```

`--bootstrap` tells dotfiler to read hook files from the dotfiles repo rather
than from the linktree (which doesn't exist yet on a fresh machine), and
implies `-u` — unpacking both the main dotfiles and zdot.

### Subsequent Unpacks

After the first setup, use:

```zsh
dotfiler setup -u       # unpack main dotfiles + all hook components
dotfiler update         # pull updates for main dotfiles + all hook components
```

### Further Reading

See [dotfiler's zdot integration docs](https://github.com/georgeharker/dotfiler/blob/main/docs/zdot-integration.md)
for the complete reference, including topology options, symlink chain details,
update lifecycle, and configuration.

---

## Getting Help

- Run `zdot_debug_info` to see system status
- Run `zdot_hooks_list --all` to see all registered hooks
- Set `ZDOT_VERBOSE=1` for detailed logging
- Check module files in `lib/` for real-world examples

For implementation details and core system architecture, see [IMPLEMENTATION.md](./IMPLEMENTATION.md).
