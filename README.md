# zdot - Modular Zsh Configuration Framework

zdot is a hook-based, dependency-aware configuration system for Zsh that makes it easy to organize your shell environment into modular, reusable components.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Creating Modules](#creating-modules)
- [Core Functions Reference](#core-functions-reference)
- [Hook System](#hook-system)
- [Debugging](#debugging)
- [Best Practices](#best-practices)

## Overview

### Key Features

- **Modular Architecture**: Split your configuration into logical modules (brew, ssh, completions, etc.)
- **Dependency Management**: Hooks automatically execute in the correct order based on their dependencies
- **Context Awareness**: Different configurations for interactive/non-interactive and login/non-login shells
- **Optional Loading**: Modules can gracefully handle missing dependencies (e.g., if homebrew isn't installed)
- **On-Demand Execution**: Support for manually-triggered phases (like cleanup tasks)
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
├── lib/                  # Your modules go here
│   ├── brew/
│   ├── ssh/
│   ├── completions/
│   └── ...
└── config/               # Static configuration files
```

### Basic Usage in .zshrc

```zsh
# Source the zdot system
source "${ZDOTDIR:-$HOME/.config/zsh}/zdot/zdot.zsh"

# Promise any manually-triggered phases
zdot_promise_phase finalize

# Load all modules from lib/ directory
zdot_load_modules

# Build execution plan from registered hooks
zdot_build_execution_plan

# Execute all hooks in dependency order
zdot_execute_all

# Later: manually trigger cleanup phase
zdot_provide_phase finalize
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
    source "${MYMODULE_PATH}/config.sh"

    zdot_success "mymodule initialized"
    return 0
}

# Register the hook
zdot_hook_register _mymodule_init interactive noninteractive \
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
zdot_hook_register _mymodule_init interactive noninteractive \
    --requires xdg-configured brew-ready \
    --provides mymodule-ready \
    --optional
```

### On-Demand Hooks (Cleanup Tasks)

For hooks that depend on manually-triggered phases:

```zsh
_mymodule_cleanup() {
    # This runs when 'finalize' phase is manually triggered
    zdot_info "Cleaning up mymodule resources..."
    
    # Cleanup temporary files, close connections, etc.
    rm -f "${TMPDIR}/mymodule-*.tmp"
    
    zdot_success "mymodule cleanup complete"
    return 0
}

# Register as on-demand hook
zdot_hook_register _mymodule_cleanup interactive noninteractive \
    --requires finalize \
    --on-demand \
    --optional
```

The `--on-demand` flag tells zdot that this hook is waiting for a manually-triggered phase and won't show up as an error if `finalize` isn't provided by another hook.

## Core Functions Reference

### Hook Registration

#### `zdot_hook_register <function> [contexts...] [flags...]`

Register a function to be called during shell initialization.

**Arguments:**
- `function`: Function name to register (e.g., `_mymodule_init`)
- `contexts`: One or more of: `interactive`, `noninteractive`, `login`, `nonlogin`

**Flags:**
- `--requires phase1 phase2 ...`: Phases this hook depends on
- `--provides phase_name`: Phase this hook provides (enables other hooks to depend on it)
- `--optional`: Hook won't cause errors if requirements are missing
- `--on-demand`: Hook depends on manually-triggered phases (won't show as error)

**Examples:**
```zsh
# Simple hook, no dependencies
zdot_hook_register _mymodule_init interactive --provides mymodule-ready

# Hook with dependencies
zdot_hook_register _mymodule_init interactive \
    --requires xdg-configured brew-ready \
    --provides mymodule-ready \
    --optional

# Cleanup hook (on-demand)
zdot_hook_register _mymodule_cleanup interactive noninteractive \
    --requires finalize \
    --on-demand
```

### Phase Management

#### `zdot_promise_phase <phase_name>`

Promise that a phase will be manually provided later. Allows hooks to depend on phases that aren't provided by other hooks.

**Example:**
```zsh
# In .zshrc, before building execution plan
zdot_promise_phase finalize
```

#### `zdot_provide_phase <phase_name>`

Manually trigger a phase, executing all hooks that were waiting for it.

**Example:**
```zsh
# At the end of .zshrc or when shutting down
zdot_provide_phase finalize
```

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

#### `zdot_base_debug`

Show comprehensive debug information:
- Loaded modules
- All registered hooks organized by phase
- On-demand hooks
- Hooks with missing requirements (errors)
- Completion system status

**Usage:**
```zsh
zdot_base_debug
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
zdot_hook_register _xdg_init interactive --provides xdg-configured

# This runs after xdg-configured
zdot_hook_register _brew_init interactive \
    --requires xdg-configured \
    --provides brew-ready

# This runs after both xdg-configured and brew-ready
zdot_hook_register _mymodule_init interactive \
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
zdot_hook_register _prompt_init interactive

# Both interactive and non-interactive
zdot_hook_register _env_init interactive noninteractive

# Only interactive login shells
zdot_hook_register _welcome_message interactive login
```

The system automatically detects the current context and only runs matching hooks.

## Debugging

### Enable Verbose Logging

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
- **On-demand Hooks**: Hooks waiting for manual triggers (marked `[on-demand]`)
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
zdot_base_debug
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
2. **Use `--on-demand` for cleanup hooks**: Hooks that depend on `finalize` or other manual phases
3. **Be specific with contexts**: Don't register in `noninteractive` unless necessary
4. **Return proper exit codes**: Return 1 on failure, 0 on success

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
zsh -c 'source ~/.zshrc && zdot_base_debug'

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

zdot_hook_register _aliases_init interactive --provides aliases-loaded
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

zdot_hook_register _docker_init interactive noninteractive \
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

zdot_hook_register _tempfiles_init interactive noninteractive \
    --provides tempfiles-ready

zdot_hook_register _tempfiles_cleanup interactive noninteractive \
    --requires finalize \
    --on-demand
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
zdot_hook_register _python_env_init interactive noninteractive \
    --requires xdg-configured \
    --provides python-env-ready

# Second hook initializes tools (depends on environment)
zdot_hook_register _python_tools_init interactive \
    --requires python-env-ready \
    --provides python-ready \
    --optional
```

---

## Getting Help

- Run `zdot_base_debug` to see system status
- Run `zdot_hooks_list --all` to see all registered hooks
- Set `ZDOT_VERBOSE=1` for detailed logging
- Check module files in `lib/` for real-world examples

For implementation details and core system architecture, see [IMPLEMENTATION.md](./IMPLEMENTATION.md).
