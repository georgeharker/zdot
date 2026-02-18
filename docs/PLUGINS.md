# Zdot Plugin System

Zdot includes a native plugin system that replaces the previous antidote-based setup while maintaining compatibility with OMZ plugins.

## Overview

The plugin system works in phases:

1. **Declaration Phase**: Plugins are declared with `zdot_use` in module files
2. **Clone Phase**: Plugins are cloned to cache on first shell startup
3. **Load Phase**: Plugins are loaded on-demand when needed (via hooks or explicit calls)

## Usage

### Declaring Plugins

```zsh
# In your module files (e.g., lib/plugins/plugins.zsh)
zdot_use Aloxaf/fzf-tab
zdot_use omz:plugins/git
zdot_use omz:lib
```

### Plugin Kinds

```zsh
zdot_use <spec>           # Normal: declare for loading in plugins-cloned phase
zdot_use_defer <spec>     # Deferred: load via zsh-defer
zdot_use_fpath <spec>    # Fpath: add to fpath only
zdot_use_path <spec>      # Path: use as directory path
```

### OMZ Plugins

Access Oh My Zsh plugins with the `omz:` prefix:

```zsh
zdot_use omz:plugins/git
zdot_use omz:plugins/docker
zdot_use omz:plugins/tmux
```

### OMZ Libraries

```zsh
zdot_use omz:lib          # Declare OMZ lib spec (libs are lazy-loaded via stubs)
zdot_use omz:plugins/nvm  # NVM with OMZ integration
```

## Plugin Management Commands

### List Plugins

```bash
zdot_list_plugins --declared    # Show plugins declared in config
zdot_list_plugins --loaded      # Show plugins that were loaded
zdot_list_plugins --installed  # Show plugins in cache
```

### Update Plugins

```bash
zdot_update_plugin              # Update all plugins
zdot_update_plugin Aloxaf/fzf-tab  # Update specific plugin
```

Aliases: `zdot-update`, `zdot-update <plugin>`

### Clean Plugins

```bash
zdot_clean_plugins --dry-run        # Show what would be removed
zdot_clean_plugins --remove-unused # Remove unused plugins
```

Alias: `zdot-clean`

## Configuration

### Cache Directory

All plugin caches are stored in `~/.cache/zdot/`:

- Plugin clones: `~/.cache/zdot/plugins/`
- Completion cache: `~/.cache/zdot/completions/`
- Plugin cache: `~/.cache/zdot/cache/`

Customize:
```zsh
zstyle ':zdot:plugins' directory /path/to/cache
```

### OMZ Theme

Set `ZSH_THEME` to load an OMZ theme:

```zsh
export ZSH_THEME="robbyrussell"
```

### NVM Lazy Loading

NVM loads lazily by default:

```zsh
zstyle ':omz:plugins:nvm' lazy yes
zstyle ':omz:plugins:nvm' lazy-cmd opencode mcp-hub
```

## Troubleshooting

### Non-Interactive Mode

The fzf module exits early in non-interactive shells. This is intentional - fzf requires zle.

### Completion Issues

If completions aren't working:
1. Check compdump: `ls -la ~/.zcompdump*`
2. Regenerate: `compinit`
3. Check fpath: `echo $fpath`
