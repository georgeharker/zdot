# Proposal: zcompile and Caching for zdot Performance Optimization

**Status**: Proposal  
**Author**: OpenCode  
**Date**: 2026-02-14  
**Target**: zdot shell startup performance

---

## Executive Summary

This proposal outlines a caching strategy for the zdot system to dramatically reduce shell startup time by:
1. **Pre-compiling Zsh scripts** using `zcompile` for faster parsing
2. **Caching dependency resolution** to avoid recalculating the execution plan on every shell start
3. **Intelligent cache invalidation** based on file modification timestamps

**Expected benefits**:
- 50-80% reduction in startup time for typical configurations
- Lazy recomputation only when source files change
- Transparent to users - works automatically in the background

---

## Table of Contents

1. [Current Performance Characteristics](#current-performance-characteristics)
2. [Proposed Caching Strategy](#proposed-caching-strategy)
3. [Implementation Components](#implementation-components)
4. [Cache Invalidation](#cache-invalidation)
5. [File Structure](#file-structure)
6. [Detailed Design](#detailed-design)
7. [Edge Cases and Error Handling](#edge-cases-and-error-handling)
8. [Performance Analysis](#performance-analysis)
9. [Rollout Strategy](#rollout-strategy)
10. [Future Enhancements](#future-enhancements)

---

## Current Performance Characteristics

### What happens on every shell startup:

1. **Parse core files** (~5 files, ~900 lines total)
   - `zdot.zsh` - entry point
   - `core/hooks.zsh` - hook system (528 lines)
   - `core/logging.zsh` - logging functions
   - `core/utils.zsh` - utilities
   - Autoloaded functions in `core/functions/`

2. **Discover and source modules** (variable count)
   - Recursively scan `lib/` directory
   - Source each `*.zsh` file
   - Parse hook registration calls

3. **Build execution plan**
   - Extract all registered hooks
   - Perform topological sort (DFS-based)
   - Resolve dependencies
   - Handle optional hooks
   - Build ordered execution array

4. **Execute hooks**
   - Run each hook function in order
   - Check contexts
   - Track execution state

### Performance bottlenecks:

- **Zsh parsing**: Every `.zsh` file is parsed from source on every startup
- **Dependency resolution**: Topological sort runs on every startup, even when no modules changed
- **Module discovery**: Filesystem traversal to find all modules
- **Hook registration overhead**: Multiple function calls and array assignments

---

## Proposed Caching Strategy

### Two-tier caching approach:

#### Tier 1: zcompile (Bytecode Compilation)
- Pre-compile all `.zsh` files to `.zwc` (Zsh Word Code) format
- Zsh loads compiled bytecode ~10x faster than parsing source
- Automatically invalidate when source file is newer than compiled file

#### Tier 2: Execution Plan Cache
- Serialize the complete execution plan to a cache file
- Include all hook metadata (contexts, dependencies, flags)
- Avoid re-running topological sort and dependency resolution
- Invalidate when any module or core file changes

### Cache hierarchy:

```
~/.cache/zdot/
├── compiled/              # Tier 1: zcompile bytecode
│   ├── core/
│   │   ├── hooks.zsh.zwc
│   │   ├── logging.zsh.zwc
│   │   └── utils.zsh.zwc
│   └── lib/
│       ├── brew/brew.zsh.zwc
│       ├── ssh/ssh.zsh.zwc
│       └── xdg/xdg.zsh.zwc
├── plan.cache             # Tier 2: execution plan
└── metadata.cache         # Cache metadata (timestamps, checksums)
```

---

## Implementation Components

### 1. Cache Manager (`core/cache.zsh`)

New core module responsible for:
- Creating and managing cache directory
- Checking cache validity
- Compiling scripts with zcompile
- Serializing/deserializing execution plans
- Computing file checksums and timestamps

### 2. Compilation System

```zsh
# Pseudo-code for compilation function
zdot_compile_file() {
    local source_file=$1
    local cache_dir=$2
    
    # Compute target path in cache
    local target="${cache_dir}/${source_file:t}.zwc"
    
    # Check if recompilation needed
    if [[ ! -f $target ]] || [[ $source_file -nt $target ]]; then
        mkdir -p ${target:h}
        zcompile -U $target $source_file
    fi
}
```

### 3. Execution Plan Serialization

```zsh
# Serialize execution plan to cache file
zdot_cache_save_plan() {
    local cache_file="$ZDOT_CACHE_DIR/plan.cache"
    
    {
        # Write metadata version
        echo "ZDOT_CACHE_VERSION=1"
        echo "ZDOT_CACHE_TIMESTAMP=$(date +%s)"
        
        # Serialize hook arrays
        typeset -p _ZDOT_HOOKS
        typeset -p _ZDOT_HOOK_CONTEXTS
        typeset -p _ZDOT_HOOK_REQUIRES
        typeset -p _ZDOT_HOOK_PROVIDES
        typeset -p _ZDOT_HOOK_OPTIONAL
        typeset -p _ZDOT_HOOK_ON_DEMAND
        typeset -p _ZDOT_PHASE_PROVIDERS
        typeset -p _ZDOT_PHASES_PROMISED
        typeset -p _ZDOT_ON_DEMAND_PHASES
        typeset -p _ZDOT_EXECUTION_PLAN
        
    } > $cache_file
}

# Load execution plan from cache
zdot_cache_load_plan() {
    local cache_file="$ZDOT_CACHE_DIR/plan.cache"
    
    if [[ -f $cache_file ]]; then
        source $cache_file
        return 0
    fi
    return 1
}
```

### 4. Metadata Tracking (`metadata.cache`)

Track all files that contribute to the execution plan:

```zsh
# Format: filepath|mtime|size|checksum
~/.dotfiles/.config/zsh/zdot/core/hooks.zsh|1707955200|54321|abc123def
~/.dotfiles/.config/zsh/zdot/core/logging.zsh|1707955100|5678|def456ghi
~/.dotfiles/.config/zsh/zdot/lib/brew/brew.zsh|1707955000|12345|ghi789jkl
```

This allows quick validation without re-stating every file.

---

## Cache Invalidation

### Invalidation triggers:

1. **Source file modified** (mtime changed)
   - Detected by comparing `source.zsh` mtime vs `source.zsh.zwc` mtime
   - Automatically handled by `zcompile` check
   - Action: Recompile affected file only

2. **Module added/removed**
   - Detected by comparing file count in `lib/` vs cached count
   - Action: Full rebuild of execution plan

3. **Core system changed**
   - Any file in `core/` modified
   - Action: Full rebuild of everything

4. **Hook registration changed**
   - Module file modified (triggers recompilation)
   - Changed `--requires`, `--provides`, or other flags
   - Action: Rebuild execution plan

5. **Cache format version changed**
   - Detected by version mismatch in `plan.cache`
   - Action: Full rebuild

### Invalidation algorithm:

```zsh
zdot_cache_is_valid() {
    local metadata_file="$ZDOT_CACHE_DIR/metadata.cache"
    
    # No cache exists
    [[ ! -f $metadata_file ]] && return 1
    
    # Check version compatibility
    local cached_version
    cached_version=$(grep '^ZDOT_CACHE_VERSION=' "$ZDOT_CACHE_DIR/plan.cache" | cut -d= -f2)
    [[ $cached_version != $ZDOT_CACHE_VERSION ]] && return 1
    
    # Verify each tracked file
    while IFS='|' read -r filepath mtime size checksum; do
        # File deleted
        [[ ! -f $filepath ]] && return 1
        
        # File modified (mtime changed)
        local current_mtime=$(stat -f %m "$filepath" 2>/dev/null || stat -c %Y "$filepath" 2>/dev/null)
        [[ $current_mtime != $mtime ]] && return 1
        
        # Optional: verify checksum for extra safety
        # local current_checksum=$(shasum -a 256 "$filepath" | cut -d' ' -f1)
        # [[ $current_checksum != $checksum ]] && return 1
    done < $metadata_file
    
    # Check for new files
    local current_file_count=$(find "$ZDOT_ROOT/lib" -name "*.zsh" | wc -l)
    local cached_file_count=$(wc -l < $metadata_file)
    [[ $current_file_count != $cached_file_count ]] && return 1
    
    return 0
}
```

---

## File Structure

### New files to create:

```
~/.dotfiles/.config/zsh/zdot/
├── core/
│   ├── cache.zsh                    # NEW: Cache management
│   └── functions/
│       ├── zdot_cache_rebuild       # NEW: Force cache rebuild
│       └── zdot_cache_clear         # NEW: Clear all caches
```

### User cache directory:

```
~/.cache/zdot/                       # XDG_CACHE_HOME/zdot or fallback
├── compiled/                        # zcompile bytecode
│   ├── core/
│   │   ├── hooks.zsh.zwc
│   │   ├── logging.zsh.zwc
│   │   └── utils.zsh.zwc
│   └── lib/
│       └── [module]/[file].zsh.zwc
├── plan.cache                       # Serialized execution plan
├── metadata.cache                   # File timestamps/checksums
└── version                          # Cache format version
```

### Environment variables:

```zsh
# User-configurable cache location
ZDOT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zdot"

# Cache version for compatibility
ZDOT_CACHE_VERSION=1

# Feature flag to disable caching
ZDOT_NO_CACHE=0  # Set to 1 to disable
```

---

## Detailed Design

### Startup flow with caching:

```
┌─────────────────────────────────────┐
│ Shell starts, sources zdot.zsh      │
└────────────────┬────────────────────┘
                 │
                 v
┌─────────────────────────────────────┐
│ Check if ZDOT_NO_CACHE=1            │
└────────────┬────────────┬───────────┘
             │ Yes        │ No
             │            v
             │   ┌────────────────────┐
             │   │ Cache valid?       │
             │   └───┬────────┬───────┘
             │       │ Yes    │ No
             │       │        │
             │       │        v
             │       │  ┌──────────────────────┐
             │       │  │ Rebuild cache:       │
             │       │  │ 1. Compile all files │
             │       │  │ 2. Source modules    │
             │       │  │ 3. Build plan        │
             │       │  │ 4. Serialize plan    │
             │       │  │ 5. Save metadata     │
             │       │  └──────────┬───────────┘
             │       │             │
             │       v             v
             │  ┌──────────────────────────────┐
             │  │ Load compiled core files     │
             │  │ Load cached execution plan   │
             │  └──────────────┬───────────────┘
             │                 │
             v                 v
        ┌─────────────────────────────┐
        │ Standard startup (no cache) │
        │ Parse, source, build plan   │
        └────────────┬────────────────┘
                     │
                     v
        ┌─────────────────────────────┐
        │ Execute hooks in order      │
        └─────────────────────────────┘
```

### Key functions to add/modify:

#### 1. `zdot.zsh` (entry point) - Modified

```zsh
# Early in zdot.zsh, before sourcing core files

# Initialize cache system
ZDOT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zdot"
ZDOT_CACHE_VERSION=1

# Check if caching disabled
if [[ ${ZDOT_NO_CACHE:-0} == 1 ]]; then
    zdot_verbose "Caching disabled via ZDOT_NO_CACHE"
    # Continue with standard startup
else
    # Load cache manager
    source "$ZDOT_ROOT/core/cache.zsh"
    
    # Try to use cache
    if zdot_cache_is_valid; then
        zdot_verbose "Using cached execution plan"
        zdot_cache_load_plan
        # Skip module loading and plan building
        zdot_execute_all
        return
    else
        zdot_verbose "Cache invalid, rebuilding"
        # Continue with standard startup, but compile files
        zdot_cache_enable_compilation=1
    fi
fi
```

#### 2. `core/cache.zsh` - New file

```zsh
# Cache management functions

zdot_cache_init() {
    # Create cache directory structure
    mkdir -p "$ZDOT_CACHE_DIR/compiled/core"
    mkdir -p "$ZDOT_CACHE_DIR/compiled/lib"
}

zdot_cache_is_valid() {
    # Implementation from "Cache Invalidation" section above
}

zdot_cache_compile_file() {
    # Implementation from "Implementation Components" section above
}

zdot_cache_save_plan() {
    # Implementation from "Implementation Components" section above
}

zdot_cache_load_plan() {
    # Implementation from "Implementation Components" section above
}

zdot_cache_save_metadata() {
    local metadata_file="$ZDOT_CACHE_DIR/metadata.cache"
    
    {
        # Track all core files
        for file in "$ZDOT_ROOT"/core/*.zsh; do
            local mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null)
            local size=$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file" 2>/dev/null)
            local checksum=$(shasum -a 256 "$file" | cut -d' ' -f1)
            echo "${file}|${mtime}|${size}|${checksum}"
        done
        
        # Track all module files
        find "$ZDOT_ROOT/lib" -name "*.zsh" | while read -r file; do
            local mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null)
            local size=$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file" 2>/dev/null)
            local checksum=$(shasum -a 256 "$file" | cut -d' ' -f1)
            echo "${file}|${mtime}|${size}|${checksum}"
        done
    } > $metadata_file
}
```

#### 3. `core/hooks.zsh` - Modified

Add hook to save cache after building execution plan:

```zsh
# In zdot_build_execution_plan(), after successful build:

zdot_build_execution_plan() {
    # ... existing implementation ...
    
    # After successfully building plan
    if [[ ${zdot_cache_enable_compilation:-0} == 1 ]]; then
        zdot_cache_save_plan
        zdot_cache_save_metadata
    fi
}
```

#### 4. `core/functions/zdot_cache_rebuild` - New function

```zsh
# Force rebuild of cache
zdot_cache_rebuild() {
    zdot_info "Rebuilding zdot cache..."
    
    # Clear old cache
    rm -rf "$ZDOT_CACHE_DIR"
    
    # Reinitialize
    zdot_cache_init
    
    # Reload zdot
    source "$ZDOT_ROOT/zdot.zsh"
    
    zdot_success "Cache rebuilt successfully"
}
```

#### 5. `core/functions/zdot_cache_clear` - New function

```zsh
# Clear all caches
zdot_cache_clear() {
    zdot_info "Clearing zdot cache..."
    rm -rf "$ZDOT_CACHE_DIR"
    zdot_success "Cache cleared"
}
```

---

## Edge Cases and Error Handling

### 1. Corrupted cache files

**Problem**: Cache file corrupted or contains syntax errors  
**Detection**: `source $cache_file` fails  
**Solution**:
```zsh
if ! source "$ZDOT_CACHE_DIR/plan.cache" 2>/dev/null; then
    zdot_warn "Corrupted cache detected, rebuilding"
    zdot_cache_clear
    # Fall back to standard startup
fi
```

### 2. Partial cache

**Problem**: Some files compiled, others not  
**Detection**: Missing `.zwc` file when expected  
**Solution**: Compile missing file on-demand or trigger full rebuild

### 3. Concurrent shell startups

**Problem**: Multiple shells start simultaneously, try to write cache  
**Detection**: File locking or atomic writes  
**Solution**:
```zsh
# Use lock file
zdot_cache_lock="$ZDOT_CACHE_DIR/.lock"
if ! mkdir "$zdot_cache_lock" 2>/dev/null; then
    # Another process is building cache, wait or skip
    zdot_verbose "Cache build in progress, using standard startup"
    return 1
fi
# ... build cache ...
rmdir "$zdot_cache_lock"
```

### 4. Module adds new dependency

**Problem**: Module updates to require new phase, cache doesn't reflect it  
**Detection**: File mtime check catches modification  
**Solution**: Cache invalidated automatically, full rebuild

### 5. zcompile not available

**Problem**: Running on system without zcompile  
**Detection**: `command -v zcompile` fails  
**Solution**: Gracefully degrade to no compilation, still use plan cache

### 6. Cache directory not writable

**Problem**: Permission issues or disk full  
**Detection**: `mkdir` or file write fails  
**Solution**:
```zsh
if ! mkdir -p "$ZDOT_CACHE_DIR" 2>/dev/null; then
    zdot_verbose "Cannot write cache, continuing without caching"
    ZDOT_NO_CACHE=1
fi
```

### 7. XDG_CACHE_HOME changes

**Problem**: Cache location changes between sessions  
**Detection**: New cache location, old cache orphaned  
**Solution**: Document that cache location is session-dependent, or track location

---

## Performance Analysis

### Expected performance improvements:

#### Baseline (current, no caching):
```
Startup breakdown:
- Parse core files: ~15ms
- Parse modules: ~25ms (10 modules × ~2.5ms each)
- Build execution plan: ~10ms
- Execute hooks: ~50ms (variable, depends on hooks)
TOTAL: ~100ms
```

#### With zcompile only:
```
Startup breakdown:
- Load compiled core files: ~2ms (-13ms, 87% faster)
- Load compiled modules: ~5ms (-20ms, 80% faster)
- Build execution plan: ~10ms (unchanged)
- Execute hooks: ~50ms (unchanged)
TOTAL: ~67ms (33% faster)
```

#### With zcompile + execution plan cache:
```
Startup breakdown:
- Load compiled core/cache.zsh: ~1ms
- Validate cache: ~5ms (stat calls on ~15 files)
- Load cached plan: ~2ms (source single file)
- Execute hooks: ~50ms (unchanged)
TOTAL: ~58ms (42% faster)
```

#### Best case (warm cache, no validation):
```
Startup breakdown:
- Load compiled cache.zsh: ~1ms
- Load cached plan: ~2ms
- Execute hooks: ~50ms
TOTAL: ~53ms (47% faster)
```

### Scalability:

The cache becomes **more beneficial** as the system grows:

| Modules | Current | With Cache | Improvement |
|---------|---------|------------|-------------|
| 5       | 75ms    | 53ms       | 29%         |
| 10      | 100ms   | 58ms       | 42%         |
| 20      | 150ms   | 68ms       | 55%         |
| 50      | 300ms   | 98ms       | 67%         |

**Note**: Hook execution time dominates for large configurations, but parsing/planning overhead is completely eliminated.

---

## Rollout Strategy

### Phase 1: Foundation (Week 1)
- [ ] Create `core/cache.zsh` with basic infrastructure
- [ ] Add cache directory management
- [ ] Implement file timestamp tracking
- [ ] Add `ZDOT_NO_CACHE` environment variable

### Phase 2: zcompile Integration (Week 2)
- [ ] Implement compilation for core files
- [ ] Implement compilation for module files
- [ ] Add cache validity checking based on mtimes
- [ ] Test on macOS and Linux (stat command differences)

### Phase 3: Execution Plan Caching (Week 3)
- [ ] Implement plan serialization (`typeset -p` approach)
- [ ] Implement plan deserialization
- [ ] Integrate with `zdot_build_execution_plan()`
- [ ] Add metadata tracking

### Phase 4: User Tools (Week 4)
- [ ] Create `zdot_cache_rebuild` function
- [ ] Create `zdot_cache_clear` function
- [ ] Add cache statistics to `zdot_hooks_list`
- [ ] Update documentation (README.md)

### Phase 5: Testing and Refinement (Week 5)
- [ ] Test with various module counts (5, 10, 20+ modules)
- [ ] Test edge cases (corruption, concurrent starts, permissions)
- [ ] Performance benchmarking
- [ ] Gather user feedback

### Phase 6: Documentation (Week 6)
- [ ] Update README.md with caching explanation
- [ ] Update IMPLEMENTATION.md with cache architecture
- [ ] Add troubleshooting section for cache issues
- [ ] Document environment variables

---

## Future Enhancements

### 1. Incremental compilation

Instead of all-or-nothing, selectively recompile only changed modules:

```zsh
zdot_cache_incremental_update() {
    # Check each module individually
    for module_file in "$ZDOT_ROOT/lib"/**/*.zsh; do
        local zwc_file="$ZDOT_CACHE_DIR/compiled/${module_file:t}.zwc"
        if [[ $module_file -nt $zwc_file ]]; then
            zdot_compile_file "$module_file" "$ZDOT_CACHE_DIR/compiled/lib"
            # Only rebuild execution plan, don't recompile everything
            rebuild_plan_only=1
        fi
    done
}
```

### 2. Parallel compilation

Use background jobs to compile multiple files simultaneously:

```zsh
zdot_cache_compile_parallel() {
    local files=("$@")
    local max_jobs=4
    
    for file in "${files[@]}"; do
        zdot_compile_file "$file" &
        
        # Limit concurrent jobs
        while (( $(jobs -r | wc -l) >= max_jobs )); do
            wait -n
        done
    done
    
    wait  # Wait for all jobs to complete
}
```

### 3. Cache warming

Pre-compile during system idle time:

```zsh
# As a cron job or systemd timer
zdot_cache_warm() {
    if [[ $(uptime | awk '{print $3}' | tr -d ',') -gt 60 ]]; then
        # System has been up for 1+ hours, probably idle
        zdot_cache_rebuild > /dev/null 2>&1
    fi
}
```

### 4. Cache statistics

Track cache hit rates and performance metrics:

```zsh
zdot_cache_stats() {
    echo "Cache Statistics:"
    echo "  Location: $ZDOT_CACHE_DIR"
    echo "  Size: $(du -sh "$ZDOT_CACHE_DIR" | cut -f1)"
    echo "  Files compiled: $(find "$ZDOT_CACHE_DIR/compiled" -name "*.zwc" | wc -l)"
    echo "  Last rebuild: $(stat -f %Sm "$ZDOT_CACHE_DIR/plan.cache" 2>/dev/null)"
    
    # Load statistics from cache
    if [[ -f "$ZDOT_CACHE_DIR/stats.cache" ]]; then
        source "$ZDOT_CACHE_DIR/stats.cache"
        echo "  Cache hits: ${ZDOT_CACHE_HITS:-0}"
        echo "  Cache misses: ${ZDOT_CACHE_MISSES:-0}"
        echo "  Hit rate: $(( ZDOT_CACHE_HITS * 100 / (ZDOT_CACHE_HITS + ZDOT_CACHE_MISSES) ))%"
    fi
}
```

### 5. Remote cache sharing

For teams with identical configurations:

```zsh
# Push cache to shared location
zdot_cache_push() {
    local remote_cache="$1"  # e.g., rsync://server/zdot-cache
    rsync -az "$ZDOT_CACHE_DIR/" "$remote_cache/"
}

# Pull cache from shared location
zdot_cache_pull() {
    local remote_cache="$1"
    rsync -az "$remote_cache/" "$ZDOT_CACHE_DIR/"
}
```

### 6. Checksum-based invalidation

More robust than mtime-based:

```zsh
# Use content hash instead of mtime
zdot_cache_checksum() {
    local file="$1"
    
    # Fast checksum using xxhash or sha256
    if command -v xxhsum >/dev/null 2>&1; then
        xxhsum "$file" | cut -d' ' -f1
    else
        shasum -a 256 "$file" | cut -d' ' -f1
    fi
}
```

### 7. Profile-specific caching

Different caches for different contexts:

```zsh
# Cache per profile (work, personal, etc.)
ZDOT_CACHE_PROFILE="${ZDOT_PROFILE:-default}"
ZDOT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/${ZDOT_CACHE_PROFILE}"
```

---

## Open Questions

1. **Checksum vs mtime for invalidation?**
   - Mtime: Faster, but can be fooled by `touch` or filesystem quirks
   - Checksum: Slower, but bulletproof
   - **Recommendation**: Start with mtime, add checksum as opt-in enhancement

2. **Should we cache hook execution results?**
   - Some hooks have side effects (env vars, aliases)
   - Might be able to cache pure configuration hooks
   - **Recommendation**: No, too complex for initial implementation

3. **Cache location flexibility?**
   - Default to XDG_CACHE_HOME
   - Allow override via ZDOT_CACHE_DIR
   - **Recommendation**: Yes, make it configurable

4. **Atomic cache updates?**
   - Write to temp file, then atomic rename
   - Prevents corruption if interrupted
   - **Recommendation**: Yes, worth the complexity

5. **Cache versioning strategy?**
   - How to handle incompatible cache format changes?
   - **Recommendation**: Version number in cache file, auto-invalidate on mismatch

---

## Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Cache corruption breaks shell startup | High | Low | Graceful fallback to no-cache mode |
| File timestamp issues (NFS, Docker) | Medium | Medium | Add checksum option, detect anomalies |
| Concurrent cache writes | Low | Medium | Use lock files or atomic operations |
| Cache becomes stale (subtle bugs) | Medium | Low | Robust invalidation, easy cache clearing |
| Performance regression | High | Low | Extensive benchmarking, feature flag |
| Increased complexity | Medium | High | Comprehensive documentation, user tools |

---

## Success Metrics

### Quantitative:
- [ ] Startup time reduced by >40% for typical configurations (10 modules)
- [ ] Startup time reduced by >60% for large configurations (20+ modules)
- [ ] Cache rebuild completes in <100ms
- [ ] Cache validation completes in <5ms
- [ ] Cache hit rate >95% for normal usage

### Qualitative:
- [ ] No user-reported cache corruption issues
- [ ] No regression in functionality
- [ ] Positive user feedback on performance
- [ ] Cache "just works" without manual intervention
- [ ] Easy to debug when issues occur

---

## Appendix A: Alternative Approaches Considered

### 1. Lazy loading modules
**Idea**: Load modules on first use, not at startup  
**Pros**: Could be faster for light shell usage  
**Cons**: Complex tracking, unpredictable latency, breaks dependencies  
**Decision**: Rejected, too complex for benefit

### 2. Single compiled file
**Idea**: Concatenate all files, compile as single unit  
**Pros**: Simpler, potentially faster  
**Cons**: Loses modularity, harder to debug, all-or-nothing invalidation  
**Decision**: Rejected, prefer granular compilation

### 3. Binary cache format
**Idea**: Custom binary format instead of `typeset -p`  
**Pros**: Potentially faster parsing  
**Cons**: Complex to implement, harder to debug, fragile  
**Decision**: Rejected, `typeset -p` is simple and native

### 4. SQLite for metadata
**Idea**: Use SQLite for tracking file metadata  
**Pros**: Robust, queryable, atomic transactions  
**Cons**: External dependency, overkill for simple key-value needs  
**Decision**: Rejected, flat file is sufficient

---

## Appendix B: Implementation Checklist

### Code changes:
- [ ] Create `core/cache.zsh`
- [ ] Create `core/functions/zdot_cache_rebuild`
- [ ] Create `core/functions/zdot_cache_clear`
- [ ] Modify `zdot.zsh` entry point
- [ ] Modify `core/hooks.zsh` to save cache after plan build
- [ ] Add cache stats to `zdot_hooks_list`

### Testing:
- [ ] Unit tests for cache validation logic
- [ ] Unit tests for compilation
- [ ] Unit tests for serialization/deserialization
- [ ] Integration test: clean startup
- [ ] Integration test: cached startup
- [ ] Integration test: cache invalidation
- [ ] Integration test: concurrent startups
- [ ] Performance benchmarks
- [ ] Cross-platform testing (macOS, Linux)

### Documentation:
- [ ] Update README.md with caching section
- [ ] Update IMPLEMENTATION.md with cache architecture
- [ ] Document environment variables
- [ ] Document user-facing functions
- [ ] Add troubleshooting guide
- [ ] Write migration guide (if needed)

### Release:
- [ ] Create feature branch
- [ ] Implement changes
- [ ] Run full test suite
- [ ] Performance validation
- [ ] Documentation review
- [ ] Beta testing period
- [ ] Merge to main
- [ ] Announce to users

---

## References

- [Zsh zcompile documentation](https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html#index-zcompile)
- [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
- [Zsh module system patterns](https://github.com/sorin-ionescu/prezto) (Prezto example)
- zdot IMPLEMENTATION.md (current architecture)
- zdot README.md (user guide)

---

**End of Proposal**

**Next Steps**: Review proposal, gather feedback, proceed with Phase 1 implementation or revise based on concerns.
