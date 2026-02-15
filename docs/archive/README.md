# Archived Documentation

This directory contains historical documentation that is no longer accurate or relevant to the current implementation.

## Files

- **CACHING-PROPOSAL.md**: Initial proposal for caching system (outdated - proposed wrong approach)
- **PROPOSAL-ZCOMPILE-CACHING.md**: Alternative caching proposal (outdated - proposed wrong approach)
- **ZCOMPILE_PROPOSAL.md**: Third caching proposal (outdated - proposed wrong approach)

## Why Archived

These proposals suggested using a separate cache directory (`~/.cache/zdot/compiled/`) for `.zwc` files. This approach doesn't work because Zsh requires `.zwc` files to be co-located with source files for automatic bytecode loading.

The actual working implementation uses co-located `.zwc` files as documented in:
- `../IMPLEMENTATION.md` - Main technical documentation (see "Caching System" section)
- `../CACHING-IMPLEMENTATION.md` - Detailed caching guide

## Historical Context

These documents show the design evolution and why certain approaches were rejected. They are preserved for historical reference but should not be used as implementation guides.

**Archived:** 2026-02-15
