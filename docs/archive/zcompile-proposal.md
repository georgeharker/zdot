# zdot zcompile and Dependency Caching Proposal

**Author**: OpenCode AI Assistant  
**Date**: 2026-02-14  
**Status**: Proposal  
**Goal**: Reduce zsh shell startup time through file compilation caching (`zcompile`) and dependency graph caching

---

## Executive Summary

This proposal outlines two complementary caching strategies to improve zdot initialization performance:

1. **File Caching (zcompile)**: Pre-compile `.zsh` source files to bytecode (`.zwc` files) with timestamp-based invalidation
2. **Dependency Graph Caching**: Cache the results of dependency resolution (topological sort) and hook registration metadata

**Expected Benefits**:
- File caching: ~30-50% reduction in parse/source time for ~28 `.zsh` files
- Dependency caching: ~80-95% reduction in hook registration and topological sort overhead
- Combined: Estimated 40-60% overall startup time reduction

**Implementation Complexity**: Low to Medium
- File caching: Straightforward, minimal changes to existing code
- Dependency caching: Moderate complexity due to invalidation logic

---

## Part 1: File Caching with zcompile

### Overview

Zsh's `zcompile` command pre-compiles shell scripts to bytecode, stored in `.zwc` (Zsh Word Code) files. When sourcing a script, zsh automatically uses the `.zwc` file if:
1. The `.zwc` file exists
2. The `.zwc` file is newer than the source file

This eliminates parsing overhead on every shell startup.

### What to Compile

**Priority 1 - Core Framework Files** (sourced on every startup):
- `/Users/geohar/.dotfiles/zdot/zdot.zsh` (entry point)
- `/Users/geohar/.dotfiles/zdot/core/*.zsh` (7 files):
  - `core.zsh`, `hooks.zsh`, `modules.zsh`, `completions.zsh`, `functions.zsh`, `logging.zsh`, `utils.zsh`

**Priority 2 - User Module Files** (sourced on every startup):
- `/Users/geohar/.dotfiles/zdot/lib/**/*.zsh` (21 files):
  - `xdg/xdg.zsh`, `env/env.zsh`, `completions/completions.zsh`, etc.

**Priority 3 - Lazy-Loaded Functions** (optional, loaded on-demand):
- `/Users/geohar/.dotfiles/zdot/core/functions/*.zsh`
- `/Users/geohar/.dotfiles/zdot/lib/*/functions/*.zsh`

**Not Compiled**:
- User-specific config files (e.g., `.zshrc`, `.zshenv`) - too dynamic
- Generated completion files - already generated/cached by completion system

### Cache Directory Structure

Store compiled files in XDG-compliant cache directory with mirrored structure:

```
${XDG_CACHE_HOME}/zdot/compiled/
├── zdot.zsh.zwc                    # Entry point
├── core/
│   ├── core.zsh.zwc
│   ├── hooks.zsh.zwc
│   ├── modules.zsh.zwc
│   ├── completions.zsh.zwc
│   ├── functions.zsh.zwc
│   ├── logging.zsh.zwc
│   └── utils.zsh.zwc
├── lib/
│   ├── xdg/
│   │   └── xdg.zsh.zwc
│   ├── env/
│   │   └── env.zsh.zwc
│   └── ...
└── functions/
    ├── core/
    │   └── <function>.zsh.zwc
    └── lib/
        └── <module>/
            └── <function>.zsh.zwc
```

**Rationale**:
- Mirrors source structure for easy mapping
- XDG-compliant (`${XDG_CACHE_HOME}` defaults to `~/.cache`)
- Separate from source tree (avoids polluting git working directory)
- Easy to clear entire cache with `rm -rf ${XDG_CACHE_HOME}/zdot/compiled`

### Compilation Strategy

**Option A: Eager Compilation (Recommended)**

Create a separate compilation utility that pre-compiles all files:

```zsh
# zdot/bin/zdot-compile (new file)
#!/usr/bin/env zsh
# Compile all zdot files to bytecode

_compile_file() {
    local src="$1"
    local dst="$2"
    
    # Create destination directory
    mkdir -p "$(dirname "${dst}")"
    
    # Compile if source is newer or destination missing
    if [[ ! -f "${dst}" || "${src}" -nt "${dst}" ]]; then
        zcompile -U "${dst}" "${src}" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "Compiled: ${src} -> ${dst}"
        else
            echo "Failed to compile: ${src}" >&2
            return 1
        fi
    fi
}

_compile_zdot() {
    local zdot_dir="${1:-${HOME}/.dotfiles/zdot}"
    local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/compiled"
    
    # Compile entry point
    _compile_file "${zdot_dir}/zdot.zsh" "${cache_dir}/zdot.zsh.zwc"
    
    # Compile core modules
    for src in "${zdot_dir}"/core/*.zsh; do
        local name="$(basename "${src}")"
        _compile_file "${src}" "${cache_dir}/core/${name}.zwc"
    done
    
    # Compile lib modules
    for src in "${zdot_dir}"/lib/**/*.zsh; do
        local rel_path="${src#${zdot_dir}/lib/}"
        _compile_file "${src}" "${cache_dir}/lib/${rel_path}.zwc"
    done
    
    # Optional: Compile functions
    # for src in "${zdot_dir}"/core/functions/*.zsh; do
    #     local name="$(basename "${src}")"
    #     _compile_file "${src}" "${cache_dir}/functions/core/${name}.zwc"
    # done
}

_compile_zdot "$@"
```

**Usage**:
```bash
# Manual compilation
~/dotfiles/zdot/bin/zdot-compile

# Integrate into dotfiles deployment
make zdot-compile

# Post-pull hook (optional)
# Add to .git/hooks/post-merge
```

**Pros**:
- Simple, predictable behavior
- No runtime overhead checking timestamps
- Clear separation of concerns (compile step vs. runtime)
- Easy to integrate into deployment/update workflows

**Cons**:
- Requires manual/scripted invocation after source changes
- User must remember to recompile after edits

---

**Option B: Lazy Compilation on Startup**

Check and compile files during zdot initialization:

```zsh
# In zdot/core/compiler.zsh (new file)

_zdot_ensure_compiled() {
    local src="$1"
    local dst="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/compiled/${src#${_ZDOT_ROOT_DIR}/}.zwc"
    
    # Create cache directory if needed
    mkdir -p "$(dirname "${dst}")"
    
    # Compile if source is newer or destination missing
    if [[ ! -f "${dst}" || "${src}" -nt "${dst}" ]]; then
        zcompile -U "${dst}" "${src}" 2>/dev/null
    fi
}

# Called before sourcing any file
_zdot_source_compiled() {
    local src="$1"
    _zdot_ensure_compiled "${src}"
    source "${src}"  # zsh automatically uses .zwc if available
}
```

**Integration Point** (in `zdot/core/modules.zsh:zdot_load_modules()`):

```zsh
# Current code (line ~45-60):
for module_file in "${_ZDOT_LIB_DIR}"/**/*.zsh(.N); do
    # ... module name detection ...
    _ZDOT_CURRENT_MODULE_NAME="${module_name}"
    _ZDOT_CURRENT_MODULE_DIR="$(dirname "${module_file}")"
    source "${module_file}"  # <-- Replace with _zdot_source_compiled
    # ...
done

# Proposed change:
for module_file in "${_ZDOT_LIB_DIR}"/**/*.zsh(.N); do
    # ... module name detection ...
    _ZDOT_CURRENT_MODULE_NAME="${module_name}"
    _ZDOT_CURRENT_MODULE_DIR="$(dirname "${module_file}")"
    _zdot_source_compiled "${module_file}"  # <-- Use compilation wrapper
    # ...
done
```

**Pros**:
- Automatic, no user intervention needed
- Always up-to-date (checks timestamps on every startup)
- Graceful degradation (falls back to source if compilation fails)

**Cons**:
- Adds timestamp check overhead on every startup (~28 stat() calls)
- First startup after edits slightly slower (compilation on-the-fly)
- More complex error handling

---

**Recommendation**: **Option A (Eager Compilation)** for simplicity and predictability. Integrate into:
1. Post-installation script (`make install` or equivalent)
2. Post-update hook (git `post-merge` hook)
3. Manual command for development (`zdot-compile`)

Fallback: If no `.zwc` files exist, zdot works normally (just slower). No breaking changes.

### Invalidation Strategy

**Timestamp-Based Invalidation** (built into zsh):
- zsh automatically checks if `.zwc` is newer than source
- If source is newer, zsh ignores `.zwc` and parses source
- No explicit invalidation logic needed

**Manual Cache Clearing**:
```bash
# Clear all compiled files
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/zdot/compiled"

# Recompile
~/dotfiles/zdot/bin/zdot-compile
```

**Invalidation Triggers**:
- Any `.zsh` file modified in `zdot/` tree
- Automatic if using Option B (lazy compilation)
- Manual recompile if using Option A (eager compilation)

### Implementation Plan - File Caching

**Phase 1: Create Compilation Utility**
1. Create `zdot/bin/zdot-compile` script
2. Implement `_compile_file()` and `_compile_zdot()` functions
3. Test compilation of all 28 source files
4. Verify `.zwc` files created in cache directory

**Phase 2: Integration**
1. Add `zdot-compile` to post-installation scripts
2. Add `zdot-compile` to git hooks (optional)
3. Update `README.md` with compilation instructions
4. Add `zdot-clean-cache` utility for clearing compiled files

**Phase 3: Testing**
1. Benchmark startup time before/after compilation
2. Verify correct invalidation (edit source, check .zwc ignored)
3. Test fallback behavior (delete .zwc, ensure still works)
4. Test on multiple machines/environments

**Phase 4: Optional Enhancements**
1. Compile lazy-loaded functions (Priority 3)
2. Add compilation status to `zdot-status` command
3. Add `--force-recompile` flag to compilation utility

**Estimated Effort**: 4-6 hours
**Risk Level**: Low (non-breaking, graceful fallback)

---

## Part 2: Dependency Graph Caching

### Overview

Currently, on every shell startup, zdot:
1. Sources all 28 module files (~28 I/O operations)
2. Each module calls `zdot_hook_register()` (~21-30 function calls)
3. Builds dependency graph with `zdot_build_execution_plan()` (topological sort via Kahn's algorithm)

Steps 2-3 are deterministic: if source files haven't changed, the dependency graph is identical.

**Caching Strategy**: After first startup, serialize:
- Hook registration metadata (`_ZDOT_HOOKS`, `_ZDOT_HOOK_CONTEXTS`, `_ZDOT_HOOK_REQUIRES`, `_ZDOT_HOOK_PROVIDES`)
- Pre-computed execution plan (`_ZDOT_EXECUTION_PLAN`)
- Phase provider mappings (`_ZDOT_PHASE_PROVIDERS`)

On subsequent startups:
- Check if cache is valid (no source files changed)
- If valid: Deserialize cached data, skip hook registration and dependency resolution
- If invalid: Rebuild, serialize new cache

### What to Cache

**Global Hook State** (from `core/hooks.zsh`):
- `_ZDOT_HOOKS` - Hook function names and metadata
- `_ZDOT_HOOK_CONTEXTS` - Context specifications (interactive/noninteractive, login/nonlogin)
- `_ZDOT_HOOK_REQUIRES` - Dependency requirements per hook
- `_ZDOT_HOOK_PROVIDES` - Phase provisions per hook
- `_ZDOT_HOOK_FLAGS` - Optional/on-demand flags per hook
- `_ZDOT_PHASE_PROVIDERS` - Reverse mapping: phase -> hooks that provide it

**Execution Plan**:
- `_ZDOT_EXECUTION_PLAN` - Pre-computed topologically sorted hook execution order

**Invalidation Metadata**:
- Checksums or timestamps of all source files (`zdot.zsh`, `core/*.zsh`, `lib/**/*.zsh`)

### Cache File Format

**Option A: Zsh Serialization (Recommended)**

Use zsh's built-in serialization with `typeset -p`:

```zsh
# Cache file: ${XDG_CACHE_HOME}/zdot/dependency-cache.zsh

# Generated by zdot-cache-builder
# DO NOT EDIT MANUALLY

# Source file timestamps (for invalidation)
typeset -A _ZDOT_CACHE_TIMESTAMPS=(
    [/Users/geohar/.dotfiles/zdot/zdot.zsh]="1234567890"
    [/Users/geohar/.dotfiles/zdot/core/core.zsh]="1234567891"
    # ... all 28 source files ...
)

# Hook metadata
typeset -A _ZDOT_HOOKS=(
    [_xdg_init]="interactive noninteractive"
    [_xdg_cleanup]="interactive noninteractive"
    # ...
)

typeset -A _ZDOT_HOOK_CONTEXTS=(
    [_xdg_init]="interactive noninteractive"
    # ...
)

typeset -A _ZDOT_HOOK_REQUIRES=(
    [_env_init]="xdg-configured"
    [_completions_finalize]="completions-paths-ready plugins-post-configured rust-ready bun-ready uv-configured"
    # ...
)

typeset -A _ZDOT_HOOK_PROVIDES=(
    [_xdg_init]="xdg-configured"
    [_env_init]="env-configured"
    # ...
)

typeset -A _ZDOT_HOOK_FLAGS=(
    [_xdg_cleanup]="on-demand"
    # ...
)

typeset -A _ZDOT_PHASE_PROVIDERS=(
    [xdg-configured]="_xdg_init"
    [env-configured]="_env_init"
    # ...
)

# Pre-computed execution plan
typeset -a _ZDOT_EXECUTION_PLAN=(
    "_xdg_init"
    "_env_init"
    "_completions_init"
    # ... full sorted order ...
)
```

**Pros**:
- Native zsh format, efficient to source
- Easy to debug (human-readable)
- Uses `typeset -p` for automatic serialization
- No external dependencies

**Cons**:
- Larger file size than binary formats
- Not as fast as binary deserialization

---

**Option B: Binary Serialization**

Use a custom binary format or zsh's internal serialization (if available):

**Pros**:
- Smaller file size
- Potentially faster deserialization

**Cons**:
- More complex to implement
- Harder to debug
- Version compatibility issues

---

**Recommendation**: **Option A (Zsh Serialization)** for simplicity, debuggability, and maintainability.

### Cache Location

```
${XDG_CACHE_HOME}/zdot/
├── dependency-cache.zsh        # Cached dependency graph
└── dependency-cache.lock       # Lock file (optional, for atomic writes)
```

**Rationale**:
- XDG-compliant
- Separate from compiled files (different invalidation rules)
- Easy to clear with `rm -rf ${XDG_CACHE_HOME}/zdot/dependency-cache.zsh`

### Cache Invalidation

**Invalidation Trigger**: Any source file modified

**Implementation Strategy**:
1. On cache creation, record timestamp (or checksum) of all source files
2. On cache load, check if any source file is newer than cached timestamp
3. If any file changed: invalidate cache, rebuild, serialize new cache
4. If no files changed: use cache

**Timestamp Collection**:

```zsh
_zdot_collect_source_timestamps() {
    typeset -gA _ZDOT_CACHE_TIMESTAMPS
    
    # Entry point
    _ZDOT_CACHE_TIMESTAMPS[${_ZDOT_ROOT_DIR}/zdot.zsh]=$(stat -f %m "${_ZDOT_ROOT_DIR}/zdot.zsh" 2>/dev/null || stat -c %Y "${_ZDOT_ROOT_DIR}/zdot.zsh")
    
    # Core modules
    for src in "${_ZDOT_ROOT_DIR}"/core/*.zsh; do
        _ZDOT_CACHE_TIMESTAMPS[${src}]=$(stat -f %m "${src}" 2>/dev/null || stat -c %Y "${src}")
    done
    
    # Lib modules
    for src in "${_ZDOT_LIB_DIR}"/**/*.zsh(.N); do
        _ZDOT_CACHE_TIMESTAMPS[${src}]=$(stat -f %m "${src}" 2>/dev/null || stat -c %Y "${src}")
    done
}
```

**Cache Validation**:

```zsh
_zdot_is_cache_valid() {
    local cache_file="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/dependency-cache.zsh"
    
    # Cache doesn't exist
    [[ ! -f "${cache_file}" ]] && return 1
    
    # Source cache to load _ZDOT_CACHE_TIMESTAMPS
    source "${cache_file}"
    
    # Check if any source file is newer than cached timestamp
    for src timestamp in ${(kv)_ZDOT_CACHE_TIMESTAMPS}; do
        local current_timestamp=$(stat -f %m "${src}" 2>/dev/null || stat -c %Y "${src}")
        if [[ ${current_timestamp} -gt ${timestamp} ]]; then
            zdot_verbose "Cache invalid: ${src} modified"
            return 1
        fi
    done
    
    return 0
}
```

### Integration Points

**Modify `zdot/core/modules.zsh:zdot_load_modules()`**:

```zsh
# Current implementation (lines ~40-70):
zdot_load_modules() {
    # ... existing code ...
    
    for module_file in "${_ZDOT_LIB_DIR}"/**/*.zsh(.N); do
        # ... detect module name ...
        _ZDOT_CURRENT_MODULE_NAME="${module_name}"
        _ZDOT_CURRENT_MODULE_DIR="$(dirname "${module_file}")"
        source "${module_file}"  # <-- Triggers hook registration
        _ZDOT_CURRENT_MODULE_NAME=""
        _ZDOT_CURRENT_MODULE_DIR=""
    done
    
    # ... existing code ...
}

# Proposed implementation with caching:
zdot_load_modules() {
    # Try to load from cache
    if _zdot_is_cache_valid; then
        zdot_verbose "Loading dependency graph from cache"
        source "${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/dependency-cache.zsh"
        return 0
    fi
    
    zdot_verbose "Cache invalid or missing, rebuilding dependency graph"
    
    # ... existing module loading code (unchanged) ...
    
    # After all modules loaded, serialize cache
    _zdot_serialize_cache
}
```

**Add `zdot/core/cache.zsh` (new file)**:

```zsh
# Cache serialization and deserialization

_zdot_serialize_cache() {
    local cache_file="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/dependency-cache.zsh"
    mkdir -p "$(dirname "${cache_file}")"
    
    {
        echo "# Generated by zdot-cache-builder"
        echo "# DO NOT EDIT MANUALLY"
        echo ""
        
        # Collect and serialize source timestamps
        _zdot_collect_source_timestamps
        typeset -p _ZDOT_CACHE_TIMESTAMPS
        
        # Serialize hook metadata
        typeset -p _ZDOT_HOOKS
        typeset -p _ZDOT_HOOK_CONTEXTS
        typeset -p _ZDOT_HOOK_REQUIRES
        typeset -p _ZDOT_HOOK_PROVIDES
        typeset -p _ZDOT_HOOK_FLAGS
        typeset -p _ZDOT_PHASE_PROVIDERS
        
        # Serialize execution plan (built by zdot_build_execution_plan)
        typeset -p _ZDOT_EXECUTION_PLAN
    } > "${cache_file}"
    
    zdot_verbose "Serialized dependency cache to ${cache_file}"
}

_zdot_is_cache_valid() {
    # ... implementation from above ...
}

_zdot_collect_source_timestamps() {
    # ... implementation from above ...
}
```

**Modify `zdot/core/hooks.zsh:zdot_build_execution_plan()`**:

```zsh
# Current implementation (lines ~300-450):
zdot_build_execution_plan() {
    # ... topological sort implementation ...
    _ZDOT_EXECUTION_PLAN=("${sorted_hooks[@]}")
}

# Proposed: Skip if cache loaded
zdot_build_execution_plan() {
    # Check if execution plan already loaded from cache
    if [[ ${#_ZDOT_EXECUTION_PLAN[@]} -gt 0 ]]; then
        zdot_verbose "Using cached execution plan"
        return 0
    fi
    
    # ... existing topological sort implementation (unchanged) ...
    _ZDOT_EXECUTION_PLAN=("${sorted_hooks[@]}")
}
```

**Modify `zdot/zdot.zsh` (entry point)**:

```zsh
# Current implementation (lines ~1-40):
# ... source core modules ...
zdot_load_modules       # <-- Loads modules, triggers hook registration
zdot_build_execution_plan   # <-- Builds dependency graph
zdot_execute_all        # <-- Executes hooks

# Proposed (no change, but internal behavior changes):
# ... source core modules (including new cache.zsh) ...
zdot_load_modules       # <-- Loads from cache OR rebuilds
zdot_build_execution_plan   # <-- No-op if cache loaded
zdot_execute_all        # <-- Executes hooks (same)
```

### Cache Invalidation Scenarios

**Scenario 1: User Edits a Module**
- User edits `lib/env/env.zsh`
- Next startup: `_zdot_is_cache_valid()` detects timestamp change
- Cache invalidated, dependency graph rebuilt
- New cache serialized

**Scenario 2: User Adds a New Module**
- User creates `lib/new-module/new-module.zsh`
- Next startup: New file not in `_ZDOT_CACHE_TIMESTAMPS`
- Cache invalidation logic detects missing file (needs enhancement)
- Cache invalidated, dependency graph rebuilt

**Enhancement Needed**: Detect new files not in cache:

```zsh
_zdot_is_cache_valid() {
    # ... existing timestamp checks ...
    
    # Check if any new files added
    for src in "${_ZDOT_ROOT_DIR}"/core/*.zsh "${_ZDOT_LIB_DIR}"/**/*.zsh(.N); do
        if [[ ! -v _ZDOT_CACHE_TIMESTAMPS[${src}] ]]; then
            zdot_verbose "Cache invalid: new file ${src}"
            return 1
        fi
    done
    
    return 0
}
```

**Scenario 3: User Deletes a Module**
- User deletes `lib/old-module/`
- Next startup: File in `_ZDOT_CACHE_TIMESTAMPS` but doesn't exist
- Cache invalidation logic detects missing file
- Cache invalidated, dependency graph rebuilt

**Enhancement Needed**: Detect deleted files:

```zsh
_zdot_is_cache_valid() {
    # ... existing checks ...
    
    # Check if any cached files deleted
    for src in ${(k)_ZDOT_CACHE_TIMESTAMPS}; do
        if [[ ! -f "${src}" ]]; then
            zdot_verbose "Cache invalid: file deleted ${src}"
            return 1
        fi
    done
    
    return 0
}
```

### Implementation Plan - Dependency Caching

**Phase 1: Cache Serialization**
1. Create `zdot/core/cache.zsh` with serialization functions
2. Implement `_zdot_serialize_cache()`, `_zdot_collect_source_timestamps()`
3. Test serialization manually (call after module load)
4. Verify cache file format and content

**Phase 2: Cache Validation**
1. Implement `_zdot_is_cache_valid()` with timestamp checking
2. Add new file detection logic
3. Add deleted file detection logic
4. Test invalidation scenarios (edit file, add file, delete file)

**Phase 3: Integration**
1. Modify `zdot_load_modules()` to load from cache
2. Modify `zdot_build_execution_plan()` to skip if cached
3. Source `core/cache.zsh` in `zdot.zsh`
4. Test end-to-end cache workflow

**Phase 4: Testing**
1. Benchmark startup time with cache vs. without
2. Test all invalidation scenarios
3. Test edge cases (corrupted cache, missing cache, empty cache)
4. Verify correct execution order from cached plan

**Phase 5: Optional Enhancements**
1. Add cache statistics to `zdot-status` command
2. Add `--skip-cache` flag to force rebuild (for debugging)
3. Add cache version number (invalidate on zdot upgrade)
4. Add checksum-based invalidation (more robust than timestamps)

**Estimated Effort**: 8-12 hours
**Risk Level**: Medium (more complex invalidation logic, potential for subtle bugs)

---

## Combined Performance Analysis

### Baseline (No Caching)

Estimated startup time breakdown:
- **File I/O + Parsing**: 28 files × ~5ms = ~140ms (varies by disk speed)
- **Hook Registration**: 21 modules × ~0.5ms = ~10ms (function calls, array operations)
- **Dependency Resolution**: Topological sort ~15-20ms (complex algorithm)
- **Hook Execution**: Variable (~50-200ms depending on hooks)
- **Total**: ~215-370ms (excluding hook execution)

### With File Caching Only

Estimated startup time breakdown:
- **File I/O + Parsing**: 28 files × ~2ms = ~56ms (`.zwc` is pre-parsed bytecode)
- **Hook Registration**: ~10ms (unchanged)
- **Dependency Resolution**: ~15-20ms (unchanged)
- **Hook Execution**: Variable (~50-200ms)
- **Total**: ~131-286ms (excluding hook execution)
- **Improvement**: ~40% reduction in parse time, ~25-30% overall

### With Dependency Caching Only

Estimated startup time breakdown:
- **File I/O + Parsing**: ~140ms (unchanged, still parsing all files)
- **Cache Validation**: ~30ms (28 stat() calls + timestamp comparisons)
- **Cache Loading**: ~5ms (source single cache file)
- **Hook Registration**: 0ms (skipped)
- **Dependency Resolution**: 0ms (skipped)
- **Hook Execution**: Variable (~50-200ms)
- **Total**: ~175-375ms (excluding hook execution)
- **Improvement**: ~10-15% reduction (less than expected due to validation overhead)

**Note**: Dependency caching alone provides minimal benefit because validation overhead (~30ms) is similar to what it saves (~25ms hook registration + dependency resolution).

### With Both File + Dependency Caching

Estimated startup time breakdown:
- **File I/O + Parsing**: ~56ms (`.zwc` files)
- **Cache Validation**: ~30ms (stat() calls, but faster with fewer files to validate if using checksums)
- **Cache Loading**: ~5ms
- **Hook Registration**: 0ms (skipped)
- **Dependency Resolution**: 0ms (skipped)
- **Hook Execution**: Variable (~50-200ms)
- **Total**: ~91-291ms (excluding hook execution)
- **Improvement**: ~50-60% reduction overall

**Synergy Effect**: File caching reduces parsing overhead, making dependency cache validation overhead relatively larger. However, combined they provide significant speedup.

### Optimization Opportunity: Fast-Path Cache Loading

If cache is valid, skip module sourcing entirely:

```zsh
zdot_load_modules() {
    if _zdot_is_cache_valid; then
        zdot_verbose "Loading from cache (fast path)"
        source "${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/dependency-cache.zsh"
        return 0
    fi
    
    # Slow path: source all modules, rebuild, serialize
    # ...
}
```

**Fast-Path Breakdown**:
- **Cache Validation**: ~30ms (28 stat() calls)
- **Cache Loading**: ~5ms (source single file)
- **Hook Registration**: 0ms (skipped)
- **Dependency Resolution**: 0ms (skipped)
- **Total**: ~35ms (excluding hook execution)
- **Improvement**: ~85% reduction compared to baseline

**Trade-off**: Module-level code (outside of hook functions) won't execute. This is acceptable because:
- Most module code is hook registration (which is cached)
- Autoload function registration can be cached (see enhancement below)
- Global variable initialization can be moved into hooks

### Enhancement: Cache Function Autoload Registrations

Currently, some modules call `zdot_module_autoload_funcs` at module load time (e.g., `lib/completions/completions.zsh:6`). In fast-path mode, this won't execute.

**Solution**: Cache autoload registrations:

```zsh
# In cache file:
typeset -a _ZDOT_CACHED_FPATH_ADDITIONS=(
    "/Users/geohar/.dotfiles/zdot/lib/completions/functions"
    # ...
)

typeset -a _ZDOT_CACHED_AUTOLOAD_FUNCS=(
    "some_completion_func"
    # ...
)
```

**Integration**:
```zsh
# After loading cache:
if [[ ${#_ZDOT_CACHED_FPATH_ADDITIONS[@]} -gt 0 ]]; then
    fpath=("${_ZDOT_CACHED_FPATH_ADDITIONS[@]}" $fpath)
fi

if [[ ${#_ZDOT_CACHED_AUTOLOAD_FUNCS[@]} -gt 0 ]]; then
    autoload -Uz "${_ZDOT_CACHED_AUTOLOAD_FUNCS[@]}"
fi
```

---

## Edge Cases and Considerations

### Edge Case 1: Corrupted Cache File

**Scenario**: Cache file corrupted (disk error, incomplete write)

**Handling**:
```zsh
_zdot_is_cache_valid() {
    # ...
    
    # Try to source cache, catch errors
    if ! source "${cache_file}" 2>/dev/null; then
        zdot_warn "Cache file corrupted, rebuilding"
        return 1
    fi
    
    # ...
}
```

### Edge Case 2: zdot Framework Upgrade

**Scenario**: User updates zdot core, but cache still valid (source files unchanged)

**Issue**: Cache format may be incompatible with new core logic

**Solution**: Add cache version number:

```zsh
# In cache file:
typeset -r _ZDOT_CACHE_VERSION="1.0.0"

# In validation:
_zdot_is_cache_valid() {
    # ...
    
    if [[ "${_ZDOT_CACHE_VERSION}" != "${_ZDOT_CURRENT_VERSION}" ]]; then
        zdot_verbose "Cache version mismatch, rebuilding"
        return 1
    fi
    
    # ...
}
```

### Edge Case 3: Module Disabled/Enabled

**Scenario**: User disables a module without deleting it (e.g., renames to `.disabled`)

**Handling**: Current glob pattern `lib/**/*.zsh` wouldn't match `.disabled` files. Cache validation would detect missing file in `_ZDOT_CACHE_TIMESTAMPS` and invalidate.

### Edge Case 4: Hook Modified Without File Change

**Scenario**: User modifies hook behavior via environment variable or external config (not in tracked `.zsh` files)

**Issue**: Cache wouldn't invalidate

**Solution**: Allow manual cache invalidation:
```bash
# User command:
zdot-clear-cache

# Or environment variable:
ZDOT_SKIP_CACHE=1 zsh
```

### Edge Case 5: Concurrent Shell Startups

**Scenario**: Two shells start simultaneously, both find invalid cache, both rebuild and serialize

**Issue**: Race condition writing cache file

**Solution**: Use atomic write with lock file:
```zsh
_zdot_serialize_cache() {
    local cache_file="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot/dependency-cache.zsh"
    local lock_file="${cache_file}.lock"
    
    # Try to acquire lock (with timeout)
    if ! mkdir "${lock_file}" 2>/dev/null; then
        zdot_verbose "Cache serialization in progress by another process"
        return 1
    fi
    
    # Serialize cache
    # ...
    
    # Release lock
    rmdir "${lock_file}" 2>/dev/null
}
```

---

## Backward Compatibility

Both caching strategies are **non-breaking**:

1. **File Caching**:
   - If no `.zwc` files exist, zsh sources `.zsh` files normally
   - Existing behavior unchanged without compilation

2. **Dependency Caching**:
   - If cache doesn't exist or is invalid, full rebuild occurs
   - Existing module loading logic unchanged (executed in slow path)

**Migration Path**:
- Users can opt-in by running `zdot-compile` and enabling caching
- No changes required to existing modules
- Framework gracefully handles missing cache

---

## Testing Strategy

### Unit Tests

1. **File Caching**:
   - Test `_compile_file()` with various source files
   - Test timestamp invalidation (edit source, verify .zwc ignored)
   - Test fallback behavior (delete .zwc, verify still works)
   - Test compilation failure handling (invalid syntax)

2. **Dependency Caching**:
   - Test `_zdot_serialize_cache()` output format
   - Test `_zdot_is_cache_valid()` with various scenarios:
     - Valid cache (no changes)
     - Invalid cache (file modified)
     - Invalid cache (new file added)
     - Invalid cache (file deleted)
     - Corrupted cache (syntax error)
   - Test cache loading and execution plan reconstruction

### Integration Tests

1. **End-to-End Startup**:
   - Measure startup time with/without caching
   - Verify correct hook execution order from cache
   - Verify correct dependency resolution from cache

2. **Invalidation Scenarios**:
   - Edit a module, verify cache invalidated
   - Add a new module, verify cache invalidated
   - Delete a module, verify cache invalidated

3. **Multi-Shell Scenarios**:
   - Start multiple shells concurrently, verify no race conditions
   - Verify cache lock mechanism works

### Performance Benchmarks

```bash
# Benchmark script
for i in {1..10}; do
    /usr/bin/time -p zsh -i -c exit 2>&1 | grep real
done | awk '{sum+=$2; count++} END {print "Average: " sum/count "s"}'
```

**Benchmarks to Collect**:
1. Baseline (no caching)
2. File caching only
3. Dependency caching only
4. Both caching strategies
5. Fast-path cache loading (with autoload caching)

---

## Recommended Implementation Order

### Phase 1: File Caching (Low Risk, High Reward)
**Estimated Time**: 4-6 hours

1. Create `zdot/bin/zdot-compile` utility
2. Test compilation manually
3. Integrate into post-installation scripts
4. Benchmark and document results
5. Update `README.md` with compilation instructions

**Deliverables**:
- Working compilation utility
- Documented compilation process
- Performance benchmarks

### Phase 2: Dependency Caching - Foundation (Medium Risk, Medium Reward)
**Estimated Time**: 8-12 hours

1. Create `zdot/core/cache.zsh` with serialization
2. Implement cache validation with timestamp checking
3. Integrate into `zdot_load_modules()`
4. Test invalidation scenarios
5. Benchmark and document results

**Deliverables**:
- Working dependency cache
- Robust invalidation logic
- Performance benchmarks

### Phase 3: Fast-Path Optimization (Low Risk, High Reward)
**Estimated Time**: 4-6 hours

1. Skip module sourcing when cache valid
2. Cache autoload function registrations
3. Test edge cases (module-level code side effects)
4. Benchmark fast-path vs. slow-path
5. Document trade-offs

**Deliverables**:
- Optimized cache loading path
- Updated documentation

### Phase 4: Polish and Edge Cases (Low Risk, Low Reward)
**Estimated Time**: 4-6 hours

1. Add cache version checking
2. Implement atomic cache writes with locking
3. Add `zdot-clear-cache` utility
4. Add cache statistics to `zdot-status`
5. Add `--skip-cache` debug flag

**Deliverables**:
- Robust error handling
- User-friendly cache management utilities

---

## Open Questions

1. **Should function autoloading be cached?**
   - Pro: Faster fast-path, fewer fpath manipulations
   - Con: More complex cache invalidation (need to track function directories)
   - Recommendation: Implement in Phase 3 if fast-path shows promise

2. **Should we use checksums instead of timestamps?**
   - Pro: More robust (handles clock skew, deliberate timestamp manipulation)
   - Con: Slower validation (~28 checksum calculations vs. 28 stat() calls)
   - Recommendation: Start with timestamps, add checksums as optional enhancement

3. **Should cache validation be parallelized?**
   - Pro: Faster validation with parallel stat() calls
   - Con: More complex implementation, may not be worth it for ~28 files
   - Recommendation: Profile first, parallelize if validation becomes bottleneck

4. **Should we cache hook execution results?**
   - Pro: Could skip hook execution entirely if nothing changed
   - Con: Very difficult to invalidate (hooks have side effects on filesystem, environment)
   - Recommendation: Out of scope for this proposal

5. **Should we compile functions lazily or eagerly?**
   - Pro (lazy): Compiles only what's used, faster first startup
   - Pro (eager): Predictable, simpler, all functions compiled upfront
   - Recommendation: Eager compilation in Phase 1, lazy as optional enhancement

---

## Conclusion

This proposal outlines two complementary caching strategies to significantly improve zdot startup performance:

1. **File Caching (zcompile)**: Pre-compile `.zsh` files to bytecode (`.zwc`)
   - **Estimated Improvement**: ~25-30% startup time reduction
   - **Risk Level**: Low (non-breaking, graceful fallback)
   - **Recommended Priority**: High (Phase 1)

2. **Dependency Graph Caching**: Cache hook metadata and execution plan
   - **Estimated Improvement**: ~10-15% alone, ~50-60% combined with file caching
   - **Risk Level**: Medium (more complex invalidation logic)
   - **Recommended Priority**: Medium (Phase 2)

**Combined Improvement**: ~50-60% startup time reduction, potentially up to ~85% with fast-path optimization.

**Implementation Effort**: ~20-30 hours total across 4 phases

**Next Steps**:
1. Review and approve proposal
2. Implement Phase 1 (file caching) as proof of concept
3. Benchmark and iterate
4. Proceed to Phase 2 if Phase 1 shows promise

---

**End of Proposal**
