# zdot Implementation Guide

This document provides technical implementation details for the zdot system. It covers the internal architecture, data structures, algorithms, and design decisions.

**Audience**: Developers working on the zdot core system or advanced users who want to understand internals.

**For users**: See [README.md](./README.md) for module creation and usage guide.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Core Components](#core-components)
- [Data Structures](#data-structures)
- [Hook Lifecycle](#hook-lifecycle)
- [Dependency Resolution](#dependency-resolution)
- [Context System](#context-system)
- [Module Loading](#module-loading)
- [Logging System](#logging-system)
- [Debugging Tools](#debugging-tools)
- [Design Decisions](#design-decisions)
- [Extension Points](#extension-points)

## Architecture Overview

### System Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. System Initialization (zdot.zsh)                         │
│    - Set up autoload paths                                   │
│    - Source core modules                                     │
│    - Initialize global data structures                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Module Loading (zdot_load_modules)                       │
│    - Scan lib/ directory for *.zsh files                    │
│    - Source each module file                                 │
│    - Modules register hooks via zdot_hook_register()        │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Phase Promises (.zshrc)                                  │
│    - User calls zdot_promise_phase() for manual phases      │
│    - Marks phases as available for dependency resolution    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Execution Planning (zdot_build_execution_plan)           │
│    - Analyze hook dependencies                               │
│    - Perform topological sort                                │
│    - Build ordered execution plan                            │
│    - Store in _ZDOT_EXECUTION_PLAN array                    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. Hook Execution (zdot_execute_all)                        │
│    - Iterate through execution plan                          │
│    - Check shell context matches                             │
│    - Execute hook function                                   │
│    - Mark phase as provided if successful                    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Manual Phase Triggering (zdot_provide_phase)             │
│    - User triggers phase (e.g., "finalize")                  │
│    - Execute waiting hooks                                   │
│    - Mark phase as provided                                  │
└─────────────────────────────────────────────────────────────┘
```

### Design Philosophy

1. **Declarative over Imperative**: Modules declare what they need and provide, system figures out execution order
2. **Fail Gracefully**: Optional hooks don't break the system if dependencies are missing
3. **Context Aware**: Different behavior for different shell types
4. **Debuggable**: Rich introspection tools for troubleshooting
5. **Extensible**: Easy to add new modules without modifying core

## Core Components

### File Structure

```
zdot/
├── zdot.zsh                    # Entry point (28 lines)
├── core/
│   ├── hooks.zsh              # Hook system (528 lines)
│   ├── logging.zsh            # Logging functions (56 lines)
│   ├── utils.zsh              # Utility functions (60 lines)
│   └── functions/             # Autoloaded functions
│       ├── zdot_hooks_list    # Hook inspection (230 lines)
│       └── ...                # Other utilities
├── lib/                       # User modules
│   ├── xdg/
│   │   └── xdg.zsh
│   ├── brew/
│   │   └── brew.zsh
│   └── ...
└── config/                    # Static config files
```

### Core Modules

#### zdot.zsh (Entry Point)

**Responsibilities:**
- Set up autoload paths for functions
- Source core modules (hooks, logging, utils)
- Initialize function autoloading
- Set the stage for module loading

**Key Code:**
```zsh
# Lines 27-34: Function autoloading setup
if [[ -d "${ZDOTDIR}/core/functions" ]]; then
    fpath=("${ZDOTDIR}/core/functions" $fpath)
    for func_file in "${ZDOTDIR}"/core/functions/*; do
        autoload -Uz "${func_file:t}"
    done
fi
```

**Design Note**: Kept intentionally minimal. All complex logic is in sourced modules.

#### core/hooks.zsh (Hook System Core)

**Responsibilities:**
- Global data structure initialization
- Hook registration (`zdot_hook_register`)
- Dependency resolution (`zdot_build_execution_plan`)
- Hook execution (`zdot_execute_all`)
- Phase management (`zdot_promise_phase`, `zdot_provide_phase`)
- Module loading (`zdot_load_modules`)

**Key Functions:**

##### `zdot_hook_register()` (lines 29-102)

Registers a hook with the system.

**Algorithm:**
1. Parse arguments (function name, contexts, flags)
2. Generate unique hook ID: `<function>@<contexts>`
3. Store metadata in global associative arrays
4. If `--on-demand`, populate `_ZDOT_ON_DEMAND_PHASES`
5. If `--provides`, create reverse mapping in `_ZDOT_PHASE_PROVIDERS`

**Validation:**
- Checks for duplicate hook IDs
- Validates context values
- Ensures at least one context is specified

##### `zdot_build_execution_plan()` (lines 104-198)

Builds ordered execution plan via topological sort.

**Algorithm:**
1. Initialize empty execution plan and tracking sets
2. For each registered hook:
   - Skip if already processed
   - Skip if contexts don't match current shell
   - Recursively process dependencies via `_resolve_hook_dependencies()`
   - Add to execution plan if all deps satisfied
3. Store result in `_ZDOT_EXECUTION_PLAN` array

**Dependency Resolution** (`_resolve_hook_dependencies`, lines 200-271):
- Recursive depth-first search
- Detects circular dependencies
- Handles optional vs required hooks
- Respects promised phases
- Skips hooks with unsatisfiable dependencies

**Edge Cases:**
- Circular dependency detection via recursion tracking
- Missing optional dependencies (hooks skipped gracefully)
- Missing required dependencies (warnings issued)
- Promised phases (treated as available even if not provided yet)
- On-demand phases (not validated, hooks won't error)

##### `zdot_execute_all()` (lines 273-314)

Executes hooks in planned order.

**Algorithm:**
1. Check execution plan exists
2. For each hook ID in plan:
   - Look up function name
   - Execute function
   - If successful, mark phase as provided
   - If failure, log error
3. Mark hook as executed (prevents re-execution)

**Execution Context:**
- Each hook runs in current shell context
- Hook return value determines success (0 = success)
- Provided phases are immediately available for downstream hooks

##### `zdot_provide_phase()` (lines 316-362)

Manually triggers a phase and executes waiting hooks.

**Algorithm:**
1. Check if phase is already provided
2. Look up hooks that provide this phase
3. For each matching hook:
   - Check context matches
   - Check all dependencies are satisfied
   - Execute hook function
   - Mark as executed
4. Mark phase as provided

**Use Case**: Cleanup hooks that run on shell exit (e.g., `finalize` phase)

#### core/logging.zsh (Logging System)

**Responsibilities:**
- Consistent log formatting
- Log level management
- Color and icon support

**Functions:**
- `zdot_info()`: Informational messages (blue info icon)
- `zdot_success()`: Success messages (green checkmark)
- `zdot_warn()`: Warning messages (yellow warning icon)
- `zdot_error()`: Error messages (red X icon)
- `zdot_verbose()`: Debug messages (only with `ZDOT_VERBOSE=1`)

**Implementation Details:**
- Uses ANSI color codes for formatting
- Icons: Unicode symbols (ℹ ✓ ⚠ ✗)
- Verbose mode controlled by `ZDOT_VERBOSE` environment variable
- All output goes to stderr (doesn't pollute stdout)

**Design Note**: Never replace `echo` statements that are function return values!

#### core/utils.zsh (Utility Functions)

**Responsibilities:**
- Debug functions
- Helper utilities
- System introspection

**Key Functions:**

##### `zdot_base_debug()` (lines 3-60)

Comprehensive debug output.

**Output Sections:**
1. Loaded modules list
2. Registered hooks (via `zdot_hooks_list`)
3. Completion system status

**Design Note**: Entry point for troubleshooting configuration issues.

##### `zdot_is_login()`, `zdot_is_interactive()` (lines 21-32)

Shell context detection.

**Implementation:**
- `zdot_is_login()`: Checks `$options[login]`
- `zdot_is_interactive()`: Checks `$options[interactive]`

**Return Values:**
- 0 = true (yes, is login/interactive)
- 1 = false (no, is not login/interactive)

#### core/functions/zdot_hooks_list (Hook Inspection)

**Responsibilities:**
- Display all registered hooks
- Categorize by phase, on-demand, or error
- Validate hook requirements
- Show context filtering

**Algorithm** (lines 48-115):
1. Detect current shell context
2. Parse `--all` flag for showing all contexts
3. Categorize each hook:
   - **Hooks by Phase**: Have `--provides` set
   - **On-demand Hooks**: Marked `--on-demand` OR have satisfiable deps but no `--provides`
   - **Error Hooks**: No `--provides`, not on-demand, have unsatisfiable requirements
4. Group phase hooks by provided phase
5. Collect on-demand hooks
6. Detect error hooks via requirement validation

**Requirement Validation** (lines 77-92):
A requirement is **satisfiable** if ANY of:
1. Provided by a hook (`_ZDOT_PHASE_PROVIDERS[$req]`)
2. Promised via `zdot_promise_phase()` (`_ZDOT_PHASES_PROMISED[$req]`)
3. Marked as on-demand (`_ZDOT_ON_DEMAND_PHASES[$req]`)

If any requirement is unsatisfiable, hook is flagged as error.

**Display Format** (lines 117-220):
```
Hooks by Phase:

Phase: brew-ready
  • _brew_init (interactive noninteractive) [optional]

Phase: xdg-configured
  • _xdg_init (interactive noninteractive)

On-demand Hooks:

  • _xdg_cleanup (interactive noninteractive) [optional] [on-demand]

⚠️ Hooks with Missing Requirements:

  • _broken_hook (interactive noninteractive)
    ✗ Missing requirement: nonexistent-phase
```

## Data Structures

### Global Associative Arrays

#### Hook Metadata

```zsh
# Hook ID → Function name
typeset -gA _ZDOT_HOOKS
# Example: _ZDOT_HOOKS["_brew_init@interactive noninteractive"]="_brew_init"

# Hook ID → Context string (space-separated)
typeset -gA _ZDOT_HOOK_CONTEXTS
# Example: _ZDOT_HOOK_CONTEXTS["_brew_init@interactive noninteractive"]="interactive noninteractive"

# Hook ID → Required phases (space-separated)
typeset -gA _ZDOT_HOOK_REQUIRES
# Example: _ZDOT_HOOK_REQUIRES["_brew_init@interactive noninteractive"]="xdg-configured"

# Hook ID → Provided phase (single value)
typeset -gA _ZDOT_HOOK_PROVIDES
# Example: _ZDOT_HOOK_PROVIDES["_brew_init@interactive noninteractive"]="brew-ready"

# Hook ID → 1 if optional
typeset -gA _ZDOT_HOOK_OPTIONAL
# Example: _ZDOT_HOOK_OPTIONAL["_brew_init@interactive noninteractive"]=1

# Hook ID → 1 if on-demand
typeset -gA _ZDOT_HOOK_ON_DEMAND
# Example: _ZDOT_HOOK_ON_DEMAND["_xdg_cleanup@interactive noninteractive"]=1
```

#### Phase Tracking

```zsh
# Phase name → Hook ID (reverse lookup for providers)
typeset -gA _ZDOT_PHASE_PROVIDERS
# Example: _ZDOT_PHASE_PROVIDERS["brew-ready"]="_brew_init@interactive noninteractive"

# Phase name → 1 if promised
typeset -gA _ZDOT_PHASES_PROMISED
# Example: _ZDOT_PHASES_PROMISED["finalize"]=1

# Phase name → 1 if actually provided at runtime
typeset -gA _ZDOT_PHASES_PROVIDED
# Example: _ZDOT_PHASES_PROVIDED["brew-ready"]=1

# Phase name → 1 if on-demand (won't validate in dependency check)
typeset -gA _ZDOT_ON_DEMAND_PHASES
# Example: _ZDOT_ON_DEMAND_PHASES["finalize"]=1
```

#### Runtime State

```zsh
# Hook ID → 1 when executed
typeset -gA _ZDOT_HOOKS_EXECUTED
# Example: _ZDOT_HOOKS_EXECUTED["_brew_init@interactive noninteractive"]=1
```

### Global Arrays

```zsh
# Ordered list of hook IDs to execute
typeset -ga _ZDOT_EXECUTION_PLAN
# Example: _ZDOT_EXECUTION_PLAN=("_xdg_init@interactive" "_brew_init@interactive" ...)
```

### Data Structure Design Decisions

**Why Associative Arrays?**
- O(1) lookup for hooks, phases, and metadata
- Natural key-value mapping
- Built-in existence checking via `${array[$key]:-}`

**Why Composite Keys?**
- Hook ID format: `<function>@<contexts>`
- Ensures uniqueness (same function, different contexts = different hooks)
- Contains all info needed for execution

**Why Separate Arrays vs Nested Structures?**
- Zsh doesn't have native nested data structures
- Separate arrays are simpler and faster
- Easier to iterate and query

**Why Space-Separated Strings for Lists?**
- Native Zsh word splitting: `${(z)string}`
- Simple to parse and iterate
- Compact storage

## Hook Lifecycle

### Registration Phase

```
Module Loaded
      ↓
zdot_hook_register() called
      ↓
Generate hook_id = "<function>@<contexts>"
      ↓
Validate arguments
      ↓
Store in _ZDOT_HOOKS[hook_id]
      ↓
Store metadata (contexts, requires, provides, optional, on-demand)
      ↓
Update reverse mappings (_ZDOT_PHASE_PROVIDERS, _ZDOT_ON_DEMAND_PHASES)
      ↓
Registration complete
```

### Planning Phase

```
zdot_build_execution_plan() called
      ↓
Initialize empty plan and tracking sets
      ↓
For each registered hook:
  ↓
  Check if contexts match current shell
  ↓
  Resolve dependencies recursively
  ↓
  All dependencies satisfied? → Add to plan
  ↓
  Missing optional dependency? → Skip gracefully
  ↓
  Missing required dependency? → Issue warning, skip
      ↓
Execution plan built
      ↓
Stored in _ZDOT_EXECUTION_PLAN array
```

### Execution Phase

```
zdot_execute_all() called
      ↓
Iterate _ZDOT_EXECUTION_PLAN
      ↓
For each hook_id:
  ↓
  Look up function name in _ZDOT_HOOKS
  ↓
  Execute function
  ↓
  Success (return 0)?
    ↓
    Mark hook as executed (_ZDOT_HOOKS_EXECUTED)
    ↓
    Mark phase as provided (_ZDOT_PHASES_PROVIDED)
  ↓
  Failure (return != 0)?
    ↓
    Log error
    ↓
    Continue to next hook
      ↓
All hooks executed
```

### Manual Phase Triggering

```
zdot_provide_phase("finalize") called
      ↓
Check if phase already provided
      ↓
Look up hooks that provide this phase
      ↓
For each matching hook:
  ↓
  Check context matches
  ↓
  Check dependencies satisfied
  ↓
  Execute hook function
  ↓
  Mark as executed
      ↓
Mark phase as provided
      ↓
Phase trigger complete
```

## Dependency Resolution

### Algorithm: Topological Sort with DFS

The dependency resolution uses a **depth-first search (DFS)** with cycle detection.

**Function**: `_resolve_hook_dependencies()` (core/hooks.zsh:200-271)

**Input:**
- `hook_id`: Hook to resolve dependencies for
- `visiting`: Array of hooks currently in recursion stack (cycle detection)
- `plan`: Current execution plan (array)

**Output:**
- Returns 0 if all dependencies satisfied
- Returns 1 if any dependency cannot be satisfied
- Modifies `plan` array by reference (adds hooks in dependency order)

**Algorithm:**

```
function resolve_dependencies(hook_id):
    # Already processed?
    if hook_id in _ZDOT_HOOKS_EXECUTED:
        return SUCCESS
    
    if hook_id in execution_plan:
        return SUCCESS
    
    # Cycle detection
    if hook_id in visiting:
        ERROR: Circular dependency detected
        return FAILURE
    
    # Mark as visiting (cycle detection)
    visiting += hook_id
    
    # Get required phases
    required_phases = _ZDOT_HOOK_REQUIRES[hook_id]
    
    # For each required phase:
    for phase in required_phases:
        # Already provided?
        if phase in _ZDOT_PHASES_PROVIDED:
            continue
        
        # Promised for later?
        if phase in _ZDOT_PHASES_PROMISED:
            continue
        
        # On-demand phase?
        if phase in _ZDOT_ON_DEMAND_PHASES:
            continue
        
        # Find provider hook
        provider_hook = _ZDOT_PHASE_PROVIDERS[phase]
        
        if provider_hook not found:
            if hook is optional:
                VERBOSE: Skipping optional hook, missing phase
                return FAILURE
            else:
                WARNING: Required phase not available
                return FAILURE
        
        # Recursively resolve provider's dependencies
        if resolve_dependencies(provider_hook) == FAILURE:
            return FAILURE
    
    # All dependencies satisfied
    # Remove from visiting set
    visiting -= hook_id
    
    # Add to execution plan
    execution_plan += hook_id
    
    return SUCCESS
```

**Key Features:**

1. **Cycle Detection**: Tracks hooks currently being visited via `visiting` set
2. **Short-Circuit**: Returns immediately if hook already processed
3. **Promised Phases**: Treats promised phases as satisfied
4. **On-Demand Phases**: Doesn't validate on-demand phases
5. **Optional Handling**: Gracefully skips optional hooks with missing deps
6. **Recursive Resolution**: Recursively processes all dependencies

### Dependency Edge Cases

#### Circular Dependencies

**Example:**
```zsh
zdot_hook_register _hook_a interactive --requires phase-b --provides phase-a
zdot_hook_register _hook_b interactive --requires phase-a --provides phase-b
```

**Detection:**
- `_resolve_hook_dependencies()` maintains `visiting` array
- When recursion encounters a hook already in `visiting`, circular dependency detected
- Error message issued, cycle broken

**Output:**
```
✗ Circular dependency detected: _hook_a@interactive → _hook_b@interactive → _hook_a@interactive
```

#### Missing Optional Dependencies

**Example:**
```zsh
zdot_hook_register _hook_a interactive --requires nonexistent-phase --optional
```

**Behavior:**
- Dependency resolution fails
- Hook is skipped silently (verbose log only)
- No error issued
- Other hooks continue normally

**Output (with `ZDOT_VERBOSE=1`):**
```
ℹ Skipping optional hook _hook_a: required phase nonexistent-phase not available
```

#### Missing Required Dependencies

**Example:**
```zsh
zdot_hook_register _hook_a interactive --requires nonexistent-phase
```

**Behavior:**
- Dependency resolution fails
- Warning issued
- Hook is skipped
- Other hooks continue

**Output:**
```
⚠ Hook _hook_a requires phase nonexistent-phase, which is not available
```

#### Promised but Never Provided Phases

**Example:**
```zsh
# In .zshrc
zdot_promise_phase special-phase  # Promised but never actually provided

# In module
zdot_hook_register _hook_a interactive --requires special-phase --provides phase-a
```

**Behavior:**
- Dependency resolution succeeds (phase is promised)
- Hook is added to execution plan
- Hook executes (may fail if it actually needs the phase)
- Phase is never marked as provided

**Risk**: Hook may fail at runtime if it truly depends on the phase

**Mitigation**: Only promise phases you will actually provide via `zdot_provide_phase()`

#### On-Demand Phases

**Example:**
```zsh
# In module
zdot_hook_register _cleanup interactive --requires finalize --on-demand

# In .zshrc (much later)
zdot_provide_phase finalize  # Manually trigger
```

**Behavior:**
- Hook is marked as on-demand
- Phase `finalize` is added to `_ZDOT_ON_DEMAND_PHASES`
- Dependency resolution doesn't validate `finalize` exists
- Hook is categorized as "on-demand" (not error)
- Hook only executes when `zdot_provide_phase finalize` is called

**Use Case**: Cleanup tasks that run on shell exit

## Context System

### Shell Context Detection

Zsh provides context information via the `$options` associative array.

**Available Contexts:**
- `interactive`: User is interacting with shell (terminal)
- `noninteractive`: Running scripts or subshells
- `login`: First shell after authentication
- `nonlogin`: Subsequent shells (new terminal tabs/windows)

**Detection Code** (core/utils.zsh:21-32):
```zsh
zdot_is_login() {
    [[ -o login ]]
}

zdot_is_interactive() {
    [[ -o interactive ]]
}
```

**Usage in Hook Registration:**
```zsh
# Interactive shells only
zdot_hook_register _prompt_init interactive

# Both interactive and non-interactive
zdot_hook_register _env_init interactive noninteractive

# All contexts (interactive, noninteractive, login, nonlogin)
zdot_hook_register _universal_init interactive noninteractive login nonlogin
```

### Context Matching Algorithm

**Function**: `zdot_build_execution_plan()` (core/hooks.zsh:128-137)

**Algorithm:**
```zsh
# Determine current context
local current_contexts=""
zdot_is_interactive && current_contexts+="interactive " || current_contexts+="noninteractive "
zdot_is_login && current_contexts+="login " || current_contexts+="nonlogin "

# For each hook, check if contexts match
for hook_id in "${(k)_ZDOT_HOOKS[@]}"; do
    local hook_contexts="${_ZDOT_HOOK_CONTEXTS[$hook_id]}"
    
    # Check if any hook context matches current context
    local match=0
    for ctx in ${(z)hook_contexts}; do
        if [[ " $current_contexts " == *" $ctx "* ]]; then
            match=1
            break
        fi
    done
    
    # Skip hook if contexts don't match
    [[ $match -eq 0 ]] && continue
    
    # Proceed with dependency resolution...
done
```

**Logic:**
- Hook must declare at least one context that matches current shell
- If hook declares `interactive` and shell is `interactive` → match
- If hook declares `interactive noninteractive` → always matches (all interactivity levels)
- If hook declares `login` and shell is `login` → match

### Context Design Decisions

**Why separate login/nonlogin from interactive/noninteractive?**
- Login shells need special setup (environment variables, authentication)
- Interactive shells need UI configuration (prompt, keybindings)
- These concerns are orthogonal

**Why allow multiple contexts per hook?**
- Avoids duplication when hook applies to multiple contexts
- Single registration can cover all cases

**Why context matching is inclusive (OR), not exclusive (AND)?**
- Hook runs if ANY declared context matches
- More flexible and intuitive
- Allows "run in interactive OR noninteractive"

## Module Loading

### Automatic Module Discovery

**Function**: `zdot_load_modules()` (core/hooks.zsh:364-397)

**Algorithm:**
```
1. Scan ${ZDOTDIR}/lib/ directory
2. Find all *.zsh files (non-recursive, only lib/ directory itself)
3. For each module file:
   a. Extract module name from filename
   b. Log loading message
   c. Source the file
4. Return count of loaded modules
```

**Code** (core/hooks.zsh:364-397):
```zsh
zdot_load_modules() {
    local module_dir="${ZDOTDIR}/lib"
    local loaded_count=0
    
    if [[ ! -d "$module_dir" ]]; then
        zdot_error "Module directory not found: $module_dir"
        return 1
    fi
    
    zdot_verbose "Loading modules from: $module_dir"
    
    # Discover and source all .zsh files in lib/
    for module_file in "${module_dir}"/**/*.zsh(N); do
        local module_name="${module_file:t:r}"  # Extract filename without extension
        
        zdot_verbose "Loading module: $module_name"
        
        if source "$module_file"; then
            ((loaded_count++))
        else
            zdot_error "Failed to load module: $module_name"
        fi
    done
    
    zdot_success "Loaded $loaded_count module(s)"
    
    return 0
}
```

**Filename Patterns:**
- Matches: `lib/*/module.zsh`
- Matches: `lib/subdir/nested/module.zsh`
- Ignores: Non-.zsh files
- Ignores: Hidden files (start with `.`)

**Design Note**: Recursive scan allows nested module organization.

### Module Isolation

**Double-Load Prevention:**

Every module should include this guard:
```zsh
[[ -n "${_MYMODULE_LOADED:-}" ]] && return 0
_MYMODULE_LOADED=1
```

**Why?**
- Prevents double-loading if module is sourced multiple times
- Avoids duplicate hook registrations
- Prevents re-initialization side effects

**Naming Convention:**
- Variable name: `_<MODULENAME>_LOADED` (uppercase, with leading underscore)
- Leading underscore indicates internal/private variable

### Module Namespacing

**Best Practices:**
- Prefix all module functions with `_<modulename>_`
- Prefix all module variables with `_<MODULENAME>_` or `<MODULENAME>_`
- Use `local` for temporary variables in functions
- Avoid polluting global namespace

**Example:**
```zsh
# Good: Namespaced
_mymodule_init() { ... }
_MYMODULE_LOADED=1
MYMODULE_CONFIG_DIR="..."

# Bad: Global namespace pollution
init() { ... }
LOADED=1
CONFIG_DIR="..."
```

## Logging System

### Implementation Details

**File**: core/logging.zsh (56 lines)

**Color Codes:**
```zsh
local -r BLUE='\033[0;34m'
local -r GREEN='\033[0;32m'
local -r YELLOW='\033[1;33m'
local -r RED='\033[0;31m'
local -r RESET='\033[0m'
```

**Icons:**
```zsh
local -r INFO_ICON="ℹ"
local -r SUCCESS_ICON="✓"
local -r WARN_ICON="⚠"
local -r ERROR_ICON="✗"
```

**Output Target:**
All logging functions output to **stderr** (`>&2`), not stdout.

**Why stderr?**
- Keeps stdout clean for function return values
- Allows piping/redirection of script output without capturing logs
- Standard convention for diagnostic messages

### Log Levels

**zdot_verbose():**
- Only shown when `ZDOT_VERBOSE=1`
- For debug/trace information
- Not shown by default

**zdot_info():**
- Always shown
- Informational messages
- Blue color, info icon (ℹ)

**zdot_success():**
- Always shown
- Success confirmations
- Green color, checkmark icon (✓)

**zdot_warn():**
- Always shown
- Warning messages (non-fatal)
- Yellow color, warning icon (⚠)

**zdot_error():**
- Always shown
- Error messages (may be fatal)
- Red color, X icon (✗)

### Logging Best Practices

**When to use each level:**

```zsh
# Verbose: Debug details
zdot_verbose "Checking for tool: $tool_name"
zdot_verbose "Found $count configuration files"

# Info: Normal informational messages
zdot_info "Initializing module: mymodule"
zdot_info "Configuring environment variables"

# Success: Confirmation of successful operations
zdot_success "Module initialized successfully"
zdot_success "Configuration loaded"

# Warn: Problems that don't prevent execution
zdot_warn "Configuration file not found, using defaults"
zdot_warn "Tool not installed, some features unavailable"

# Error: Problems that prevent execution
zdot_error "Required dependency not found: $dep"
zdot_error "Failed to initialize: $error_message"
```

**Do's and Don'ts:**

✅ **DO:**
- Use logging functions for all user-visible messages
- Include context in messages (module name, what's happening)
- Make error messages actionable (tell user what to do)

❌ **DON'T:**
- Replace `echo` in functions that return values
- Replace `echo` in `core/logging.zsh` itself
- Use `echo` for debug/informational output
- Use `print` or `printf` instead of logging functions

## Debugging Tools

### zdot_base_debug()

**Purpose**: Show comprehensive system state for troubleshooting.

**Location**: core/utils.zsh:3-60

**Output Sections:**

1. **Loaded Modules** (lines 5-12):
   - Lists all files sourced from `lib/` directory
   - Helps verify which modules are loaded
   - Extracted from `$ZDOTDIR/lib/**/*.zsh` files

2. **Registered Hooks** (lines 14-16):
   - Calls `zdot_hooks_list` to show hook organization
   - Shows phases, on-demand hooks, and errors

3. **Completion Status** (lines 18-60):
   - Shows completion commands to be generated
   - Shows live completion functions
   - Helps debug completion issues

**Usage:**
```zsh
zdot_base_debug
```

**When to use:**
- Configuration not working as expected
- Hooks not executing
- Understanding execution order
- Verifying module loading

### zdot_hooks_list()

**Purpose**: Display registered hooks organized by category.

**Location**: core/functions/zdot_hooks_list (230 lines)

**Arguments:**
- `--all`: Show hooks for all contexts (default: only active context)

**Output Sections:**

1. **Hooks by Phase** (lines 117-155):
   - Groups hooks by the phase they provide
   - Shows contexts and flags (`[optional]`)
   - Standard hooks that provide phases

2. **On-demand Hooks** (lines 157-190):
   - Hooks marked `--on-demand`
   - Hooks without `--provides` but with satisfiable deps
   - Marked with `[on-demand]` indicator
   - Not errors, waiting for manual trigger

3. **Hooks with Missing Requirements** (lines 192-220):
   - Hooks with unsatisfiable dependencies
   - Shows which specific phases are missing
   - True configuration errors
   - Uses warning/error colors

**Usage:**
```zsh
zdot_hooks_list           # Active context only
zdot_hooks_list --all     # All contexts
```

**When to use:**
- Understanding hook organization
- Debugging dependency issues
- Finding configuration errors
- Verifying module registration

### Verbose Mode

**Enable:**
```zsh
export ZDOT_VERBOSE=1
source ~/.zshrc
```

**What it shows:**
- Module loading progress
- Hook registration details
- Dependency resolution steps
- Phase provisions
- Skipped hooks and reasons

**Example output:**
```
ℹ Loading modules from: /Users/user/.config/zsh/zdot/lib
ℹ Loading module: xdg
ℹ Loading module: brew
ℹ Registering hook: _xdg_init (interactive noninteractive) provides xdg-configured
ℹ Registering hook: _brew_init (interactive noninteractive) provides brew-ready
ℹ Building execution plan
ℹ Resolving dependencies for: _brew_init@interactive noninteractive
ℹ Required phase xdg-configured provided by _xdg_init@interactive noninteractive
ℹ Adding hook to plan: _xdg_init@interactive noninteractive
ℹ Adding hook to plan: _brew_init@interactive noninteractive
ℹ Executing hook: _xdg_init
✓ xdg initialized
ℹ Phase provided: xdg-configured
ℹ Executing hook: _brew_init
✓ brew initialized
ℹ Phase provided: brew-ready
```

### Manual Inspection

**Global Arrays:**
```zsh
# Show execution plan
print -l "${_ZDOT_EXECUTION_PLAN[@]}"

# Show all registered hooks
print -l "${(k)_ZDOT_HOOKS[@]}"

# Show provided phases
print -l "${(k)_ZDOT_PHASES_PROVIDED[@]}"

# Show executed hooks
print -l "${(k)_ZDOT_HOOKS_EXECUTED[@]}"

# Show phase providers
for phase in "${(k)_ZDOT_PHASE_PROVIDERS[@]}"; do
    echo "$phase -> ${_ZDOT_PHASE_PROVIDERS[$phase]}"
done
```

**Hook Metadata:**
```zsh
# Show specific hook details
hook_id="_brew_init@interactive noninteractive"

echo "Function: ${_ZDOT_HOOKS[$hook_id]}"
echo "Contexts: ${_ZDOT_HOOK_CONTEXTS[$hook_id]}"
echo "Requires: ${_ZDOT_HOOK_REQUIRES[$hook_id]}"
echo "Provides: ${_ZDOT_HOOK_PROVIDES[$hook_id]}"
echo "Optional: ${_ZDOT_HOOK_OPTIONAL[$hook_id]:-0}"
echo "On-demand: ${_ZDOT_HOOK_ON_DEMAND[$hook_id]:-0}"
```

## Design Decisions

### Why Hook-Based Architecture?

**Problem**: Traditional zsh configs become monolithic and hard to maintain.

**Solution**: Hook-based system with dependency resolution.

**Benefits:**
1. **Modularity**: Each concern in separate module
2. **Reusability**: Modules can be shared across configs
3. **Correct Ordering**: System determines execution order automatically
4. **Graceful Degradation**: Optional hooks don't break system
5. **Testability**: Modules can be tested independently

**Trade-offs:**
- More complex than simple sourcing
- Requires understanding dependency model
- Upfront setup cost

### Why Topological Sort for Dependencies?

**Problem**: Need to execute hooks in dependency order.

**Alternatives Considered:**
1. **Manual ordering**: User specifies order (brittle, error-prone)
2. **Priority numbers**: User assigns priorities (doesn't express relationships)
3. **Dependency resolution**: System figures out order (chosen)

**Why chosen:**
- Expresses actual relationships, not arbitrary order
- Automatically handles complex dependency graphs
- Catches circular dependencies
- More maintainable as modules are added/removed

### Why Associative Arrays vs. Structs?

**Problem**: Need to store hook metadata.

**Zsh Limitation**: No native nested data structures or structs.

**Alternatives Considered:**
1. **Separate arrays per metadata field**: Chosen
2. **Serialized strings**: `"field1=value1;field2=value2"` (parsing overhead)
3. **Namespaced variables**: `_ZDOT_HOOK_${hook_id}_PROVIDES` (dynamic variable names, messy)

**Why chosen:**
- Clean separation of concerns
- O(1) lookup
- Easy to query and iterate
- No parsing overhead

### Why Composite Hook IDs?

**Format**: `<function>@<contexts>`

**Example**: `_brew_init@interactive noninteractive`

**Problem**: Same function registered for different contexts.

**Alternatives Considered:**
1. **Function name only**: Doesn't handle multiple contexts (rejected)
2. **Sequential IDs**: `hook_1`, `hook_2` (loses semantic meaning)
3. **Composite keys**: Chosen

**Why chosen:**
- Unique identification
- Embeds metadata in key
- Human-readable
- Sortable and filterable

### Why Optional Flag?

**Problem**: Some hooks depend on external tools (homebrew, docker, etc.) that might not be installed.

**Alternatives Considered:**
1. **Always fail if deps missing**: Breaks system for missing tools (rejected)
2. **Ignore all missing deps**: Hides real errors (rejected)
3. **Explicit optional flag**: Chosen

**Why chosen:**
- Explicit intent (module author decides)
- Graceful degradation for optional features
- Errors shown for truly broken configs

### Why On-Demand Flag?

**Problem**: Some hooks depend on manually-triggered phases (like `finalize`). These were showing up as errors in `zdot_hooks_list` even though they're intentional.

**Alternatives Considered:**
1. **Promise all manual phases**: Requires user action, easy to forget (rejected)
2. **Assume all non-provided phases are manual**: Hides real errors (rejected)
3. **Explicit on-demand flag**: Chosen

**Why chosen:**
- Explicit intent (module author decides)
- Distinguishes "waiting for manual trigger" from "broken config"
- Improves debug output clarity
- Doesn't require user to promise phases

### Why Autoloading for Functions?

**Problem**: Sourcing all utility functions upfront is slow.

**Solution**: Zsh autoloading - functions loaded on first use.

**Benefits:**
- Faster startup (only load what's used)
- Cleaner namespace (functions not defined until needed)
- Better organization (one function per file)

**Setup** (zdot.zsh:27-34):
```zsh
fpath=("${ZDOTDIR}/core/functions" $fpath)
for func_file in "${ZDOTDIR}"/core/functions/*; do
    autoload -Uz "${func_file:t}"
done
```

**Trade-offs:**
- Requires proper `fpath` setup
- Functions must be in separate files
- Slight delay on first use (negligible)

## Extension Points

### Adding New Core Functions

**Location**: `core/functions/`

**Steps:**
1. Create file with function name: `core/functions/my_function`
2. Write function (file contains only function definition)
3. Function is automatically autoloaded (no changes to zdot.zsh needed)

**Example** (`core/functions/my_function`):
```zsh
# Description of what this function does
my_function() {
    local arg1="$1"
    
    # Function implementation
    
    return 0
}
```

**Conventions:**
- One function per file
- Filename matches function name
- Include docstring comment
- Return 0 on success, non-zero on failure

### Adding New Global Arrays

**Location**: `core/hooks.zsh` (lines 10-20)

**Steps:**
1. Declare array with `typeset -gA` (associative) or `typeset -ga` (regular)
2. Document purpose in comment
3. Initialize in same location as other arrays

**Example:**
```zsh
# My new tracking array: key -> value
typeset -gA _ZDOT_MY_NEW_ARRAY
```

**Naming Convention:**
- Always start with `_ZDOT_`
- All caps for arrays
- Descriptive name

### Adding New Flags to zdot_hook_register()

**Location**: `core/hooks.zsh` (lines 29-102)

**Steps:**

1. Add flag to usage documentation (lines 29-35):
```zsh
# Usage: zdot_hook_register <function> [contexts...] [--my-flag]
```

2. Initialize local variable (lines 38-44):
```zsh
local my_flag=0
```

3. Add case in argument parsing loop (lines 48-73):
```zsh
--my-flag)
    my_flag=1
    ;;
```

4. Store in global array (after line 92):
```zsh
[[ $my_flag -eq 1 ]] && _ZDOT_HOOK_MY_FLAG[$hook_id]=1
```

5. Declare global array at top of file (lines 10-20):
```zsh
typeset -gA _ZDOT_HOOK_MY_FLAG
```

6. Update `zdot_hooks_list` to display flag (core/functions/zdot_hooks_list)

### Adding New Log Levels

**Location**: `core/logging.zsh`

**Steps:**

1. Define color and icon:
```zsh
local -r CYAN='\033[0;36m'
local -r NOTICE_ICON="➜"
```

2. Create logging function:
```zsh
zdot_notice() {
    echo -e "${CYAN}${NOTICE_ICON}${RESET} $*" >&2
}
```

3. Document in README.md

**Pattern**: All logging functions follow same structure:
- Color + Icon + Message
- Output to stderr (`>&2`)
- Use `echo -e` for ANSI codes

### Adding New Debug Commands

**Location**: `core/functions/` (new file) or `core/utils.zsh`

**Steps:**

1. Create function:
```zsh
zdot_debug_phases() {
    echo "=== Phase Status ==="
    echo "Provided phases:"
    for phase in "${(k)_ZDOT_PHASES_PROVIDED[@]}"; do
        echo "  ✓ $phase"
    done
    echo "Promised phases:"
    for phase in "${(k)_ZDOT_PHASES_PROMISED[@]}"; do
        echo "  ⏳ $phase"
    done
}
```

2. If in new file, place in `core/functions/` for autoloading
3. If in `core/utils.zsh`, it's immediately available
4. Document in README.md

### Modifying Dependency Resolution

**Location**: `core/hooks.zsh` `_resolve_hook_dependencies()` (lines 200-271)

**Caution**: This is core logic. Changes can break system.

**Common modifications:**

1. **Change skip behavior**: Modify how optional hooks are handled (lines 244-252)
2. **Add new phase types**: Extend logic for promised/on-demand phases (lines 227-239)
3. **Improve cycle detection**: Enhance error messages (lines 211-217)

**Testing**: After modifications, test with:
- Circular dependencies
- Missing optional dependencies
- Missing required dependencies
- Complex dependency graphs (3+ levels deep)

### Creating Custom Phase Management

**Use Case**: Custom lifecycle phases beyond `finalize`.

**Example**: Add a `shutdown` phase for cleanup when shell exits.

**Implementation:**

1. In `.zshrc`, promise phase:
```zsh
zdot_promise_phase shutdown
```

2. In module, register hook:
```zsh
zdot_hook_register _mymodule_shutdown interactive noninteractive \
    --requires shutdown \
    --on-demand
```

3. In `.zshrc`, trigger on exit:
```zsh
zshexit() {
    zdot_provide_phase shutdown
}
```

**Result**: `_mymodule_shutdown` runs automatically on shell exit.

---

## Performance Considerations

### Startup Time

**Critical Path:**
1. Source zdot.zsh (~28 lines, fast)
2. Source core modules (~650 total lines, fast)
3. Load modules from lib/ (varies, usually <1000 lines)
4. Build execution plan (O(n²) in worst case, n=number of hooks)
5. Execute hooks (depends on hook implementations)

**Bottlenecks:**
- **Module initialization**: External commands (brew, eval, etc.)
- **Completion loading**: Can be slow for large completion systems

**Optimizations:**
1. **Lazy loading**: Use autoloaded functions
2. **Conditional execution**: Skip hooks in noninteractive shells
3. **Caching**: Store expensive computation results
4. **Defer loading**: Use plugins like `romkatv/zsh-defer` for non-critical features

### Memory Usage

**Global Arrays**: Each hook adds ~5-7 entries to global arrays. With 20 hooks:
- ~100-140 array entries
- ~10KB memory overhead
- Negligible impact

**Execution Plan**: Stored as simple array, minimal memory.

**Phase Tracking**: Associative arrays, O(1) lookup, minimal overhead.

**Overall**: zdot's memory footprint is negligible (<50KB).

---

## Caching System

zdot uses Zsh's native bytecode compilation (`zcompile`) to improve startup performance. The caching system creates `.zwc` (Zsh Word Code) bytecode files that are co-located with source files, allowing Zsh to use pre-compiled bytecode transparently.

### How Zsh Bytecode Works

Zsh has built-in support for bytecode compilation that works automatically:

1. **Compilation**: The `zcompile` command converts `.zsh` files to `.zwc` bytecode files
2. **Co-location**: `.zwc` files MUST be in the same directory as the source file
3. **Automatic usage**: When you `source file.zsh`, Zsh automatically looks for `file.zsh.zwc`
4. **Transparent loading**: If `.zwc` exists and is newer than `.zsh`, Zsh uses the bytecode
5. **No code changes**: Module loading code just sources `.zsh` files normally

This is standard Zsh behavior - zdot doesn't need any special logic to use bytecode files.

### Architecture

zdot implements **two types of caching**:

#### 1. Module Caching

Each module file (`*.zsh`) gets a co-located bytecode file:

```
~/.config/zsh/zdot/core/base.zsh      → base.zsh.zwc (co-located)
~/.config/zsh/zdot/lib/git/git.zsh    → git.zsh.zwc (co-located)
```

Implementation:
```zsh
# Create bytecode file next to source file
zcompile module.zsh            # Creates module.zsh.zwc

# Load module (Zsh automatically uses .zwc if available)
source module.zsh              # Zsh uses module.zsh.zwc transparently
```

#### 2. Function Caching

Function directories get compiled into a single `.zwc` file:

```
~/.config/zsh/zdot/lib/git/functions/
├── git-status
├── git-branch
└── functions.zwc              # Contains all functions (co-located)
```

Implementation:
```zsh
# Compile all functions in directory into one .zwc file
zcompile functions.zwc func1 func2 func3

# Add directory to fpath (Zsh finds .zwc automatically)
fpath=(~/zdot/lib/git/functions $fpath)
autoload -Uz git-status git-branch
```

#### 3. Execution Plan Caching (Separate System)

The execution plan is cached separately in `~/.cache/zdot/plans/`:

```
~/.cache/zdot/plans/
├── execution_plan.zsh         # Serialized execution plan
└── execution_plan.zsh.zwc     # Compiled execution plan
```

This is a distinct caching mechanism from module/function caching.

### Implementation Details

#### Cache Creation

The `zdot_cache_compile_file()` function handles bytecode compilation:

```zsh
zdot_cache_compile_file() {
    local source_file="$1"
    
    # Co-locate .zwc file next to source file
    local zwc_file="${source_file}.zwc"
    
    # Check if recompilation needed
    if [[ ! -f "$zwc_file" ]] || [[ "$source_file" -nt "$zwc_file" ]]; then
        zcompile "$source_file"
    fi
}
```

Location: `~/.config/zsh/zdot/core/cache.zsh:528`

#### Module Loading

Modules are loaded through `zdot_module_source()`:

```zsh
zdot_module_source() {
    local module_file="$1"
    
    # Compile if caching enabled
    if zdot_cache_enabled; then
        zdot_cache_compile_file "$module_file"
    fi
    
    # Source the .zsh file (Zsh uses .zwc automatically)
    source "$module_file"
}
```

Location: `~/.config/zsh/zdot/core/utils.zsh:68`

#### Function Loading

Functions are compiled and loaded via `zdot_module_autoload_funcs()`:

```zsh
zdot_module_autoload_funcs() {
    local func_dir="$1"
    
    # Compile functions into co-located .zwc file
    if zdot_cache_enabled; then
        zdot_cache_compile_functions "$func_dir"
    fi
    
    # Add directory to fpath (with co-located .zwc)
    fpath=("$func_dir" $fpath)
    
    # Autoload functions (Zsh uses .zwc automatically)
    autoload -Uz ${func_dir}/*(:t)
}
```

Location: `~/.config/zsh/zdot/core/functions.zsh:127`

### Configuration

#### Enabling/Disabling

Control caching with zstyle:

```zsh
# Enable caching (default in .zshrc)
zstyle ':zdot:cache' enabled yes

# Disable caching
zstyle ':zdot:cache' enabled no
```

Check cache status:
```zsh
zdot_cache_enabled && echo "Caching enabled" || echo "Caching disabled"
```

#### Cache Invalidation

Remove all bytecode files to force recompilation:

```zsh
# Remove all .zwc files
zdot_cache_invalidate

# Restart shell to recompile
exec zsh
```

This deletes:
- All `*.zsh.zwc` files in `~/.config/zsh/zdot/`
- All `*.zwc` files in function directories
- The execution plan cache in `~/.cache/zdot/plans/`

### Cache File Locations

With zdot installed, bytecode files are co-located with source files:

```
~/.config/zsh/zdot/                    (symlink to .dotfiles)
├── core/
│   ├── base.zsh
│   ├── base.zsh.zwc                   ← Co-located bytecode
│   ├── cache.zsh
│   ├── cache.zsh.zwc                  ← Co-located bytecode
│   └── ...
├── lib/
│   ├── git/
│   │   ├── git.zsh
│   │   ├── git.zsh.zwc                ← Co-located bytecode
│   │   └── functions/
│   │       ├── git-status
│   │       ├── git-branch
│   │       └── functions.zwc          ← Function cache
│   └── ...
└── ...

~/.cache/zdot/plans/                   (separate plan cache)
├── execution_plan.zsh
└── execution_plan.zsh.zwc
```

**Total**: ~56 `.zwc` files co-located with source files:
- 8 core module cache files
- 22 library module cache files
- 26 function cache files

### Performance Impact

Bytecode compilation provides significant performance improvements:

- **Startup time**: ~0.40-0.42 seconds with caching enabled
- **Parsing speed**: ~10x faster with pre-compiled bytecode
- **Cache overhead**: Minimal (~1-2ms to check timestamps)
- **Disk usage**: ~200-300KB for all `.zwc` files

The performance gain is most noticeable during shell startup, where dozens of modules and functions are loaded.

### Why Co-location?

The co-location strategy (`.zwc` next to `.zsh`) is **required** by Zsh's design:

1. **Built-in behavior**: When `source file.zsh` is called, Zsh automatically looks for `file.zsh.zwc` in the same directory
2. **Automatic usage**: If found and newer, Zsh uses bytecode transparently - no code changes needed
3. **Function compatibility**: Functions in `fpath` work correctly with co-located `.zwc` files
4. **Simplicity**: No special loading logic required - just compile and source normally

Alternative approaches (separate cache directory) don't work because:
- Zsh won't find `.zwc` files in different directories
- Sourcing `.zwc` files directly causes parse errors
- Function autoloading fails with non-co-located bytecode

### Troubleshooting

#### Cache not being used

If performance doesn't improve:

```zsh
# Check if caching is enabled
zstyle -L ':zdot:cache' enabled

# Verify .zwc files exist
ls -la ~/.config/zsh/zdot/core/*.zwc
ls -la ~/.config/zsh/zdot/lib/*/*.zwc

# Invalidate and regenerate cache
zdot_cache_invalidate
exec zsh
```

#### Stale bytecode

If code changes aren't reflected:

```zsh
# .zwc files are automatically updated if source is newer
# Force regeneration:
zdot_cache_invalidate
exec zsh
```

#### Debug cache operations

Enable debugging to see cache operations:

```zsh
# In .zshrc, before zdot loads
zstyle ':zdot:debug' enabled yes
zstyle ':zdot:debug' verbose yes
```

---

## Contributing Guidelines

### Code Style

**Indentation**: 4 spaces (use spaces, not tabs)

**Whitespace**:
- Strip trailing whitespace
- Blank lines have no indent
- One blank line between functions

**Naming:**
- Functions: `snake_case` with prefix (`zdot_` or `_modulename_`)
- Variables: `snake_case` (local), `UPPER_CASE` (global)
- Arrays: `_ZDOT_UPPER_CASE` (global)

**Comments:**
- Document non-obvious logic
- Use docstrings for functions
- Explain "why", not "what"

### Testing Changes

Before submitting changes:

1. **Test all contexts:**
```zsh
# Interactive
zsh -i -c 'zdot_base_debug'

# Non-interactive
zsh -c 'zdot_base_debug'

# Login
zsh -l -c 'zdot_base_debug'
```

2. **Test edge cases:**
- Circular dependencies
- Missing dependencies
- Optional vs required
- On-demand hooks

3. **Test with verbose logging:**
```zsh
ZDOT_VERBOSE=1 zsh -c 'source ~/.zshrc'
```

4. **Verify output:**
```zsh
zdot_hooks_list --all
zdot_base_debug
```

### Documentation

When adding features:

1. Update README.md (user-facing documentation)
2. Update IMPLEMENTATION.md (technical details)
3. Add examples
4. Document new functions/flags
5. Update design decisions section if relevant

---

## Troubleshooting Guide

### Hook Not Executing

**Symptoms:**
- Hook registered but not running
- Phase not provided

**Debug Steps:**
1. Check if hook is in execution plan:
   ```zsh
   print -l "${_ZDOT_EXECUTION_PLAN[@]}" | grep hook_name
   ```

2. Check contexts match:
   ```zsh
   zdot_hooks_list --all  # Look for your hook
   ```

3. Enable verbose logging:
   ```zsh
   ZDOT_VERBOSE=1 source ~/.zshrc
   ```

4. Check for dependency issues:
   ```zsh
   zdot_hooks_list  # Look in error section
   ```

**Common Causes:**
- Context mismatch (hook declares `login`, shell is `nonlogin`)
- Missing dependency (check `--optional` flag)
- Hook returns non-zero (check function implementation)
- Circular dependency (check verbose output)

### Phase Not Available

**Symptoms:**
- Hook requires phase that doesn't exist
- Shows up in error section of `zdot_hooks_list`

**Debug Steps:**
1. Check if phase is provided by any hook:
   ```zsh
   echo "${_ZDOT_PHASE_PROVIDERS[phase-name]}"
   ```

2. Check if phase is promised:
   ```zsh
   echo "${_ZDOT_PHASES_PROMISED[phase-name]}"
   ```

3. Check if phase is on-demand:
   ```zsh
   echo "${_ZDOT_ON_DEMAND_PHASES[phase-name]}"
   ```

**Solutions:**
- Promise phase if manually triggered: `zdot_promise_phase phase-name`
- Mark hook as on-demand: `--on-demand` flag
- Fix phase name typo
- Add module that provides the phase

### Circular Dependency

**Symptoms:**
- Error message about circular dependency
- Hooks not executing

**Debug Steps:**
1. Look at error message:
   ```
   ✗ Circular dependency detected: _hook_a → _hook_b → _hook_a
   ```

2. Trace dependency chain:
   - _hook_a requires phase-b
   - _hook_b provides phase-b but requires phase-a
   - _hook_a provides phase-a
   - Cycle: a → b → a

**Solutions:**
- Remove circular dependency by breaking chain
- Combine hooks into single hook
- Use intermediate phase to break cycle

### Module Not Loading

**Symptoms:**
- Module file exists but not showing in `zdot_base_debug`
- Hooks not registered

**Debug Steps:**
1. Check file location:
   ```zsh
   ls -la ~/.dotfiles/.config/zsh/zdot/lib/mymodule/mymodule.zsh
   ```

2. Check file is sourced:
   ```zsh
   ZDOT_VERBOSE=1 source ~/.zshrc | grep "Loading module: mymodule"
   ```

3. Check for syntax errors:
   ```zsh
   zsh -n ~/.dotfiles/.config/zsh/zdot/lib/mymodule/mymodule.zsh
   ```

**Common Causes:**
- File not named `*.zsh`
- Syntax error in module file
- File is in wrong directory
- File has incorrect permissions
- Double-load guard returning early

---

For user-focused documentation and examples, see [README.md](./README.md).
