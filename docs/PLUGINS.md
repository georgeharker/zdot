# Zdot Plugin System

Zdot includes a native plugin system that replaces the previous antidote-based setup while maintaining compatibility with OMZ plugins.

## Overview

The plugin system works in phases:

1. **Declaration Phase**: Plugins are declared with `zdot_use_plugin` in module files
2. **Clone Phase**: Plugins are cloned to cache on first shell startup
3. **Load Phase**: Plugins are loaded on-demand when needed (via hooks or explicit calls)

## Usage

### Declaring Plugins

```zsh
# In your module files (e.g., lib/plugins/plugins.zsh)
zdot_use_plugin Aloxaf/fzf-tab
zdot_use_plugin omz:plugins/git
zdot_use_plugin omz:lib
```

### Plugin Kinds

```zsh
zdot_use_plugin <spec>           # Normal: declare for loading in plugins-cloned phase
zdot_use_plugin <spec> defer     # Deferred: load via zsh-defer
zdot_use_fpath <spec>            # Fpath: add to fpath only (legacy compatibility)
zdot_use_path <spec>             # Path: use as directory path (legacy compatibility)
```

> **Note:** `zdot_use_defer` is deprecated. Use `zdot_use_plugin <spec> defer` instead.
> `zdot_use_fpath` and `zdot_use_path` still exist for legacy compatibility.

### OMZ Plugins

Access Oh My Zsh plugins with the `omz:` prefix:

```zsh
zdot_use_plugin omz:plugins/git
zdot_use_plugin omz:plugins/docker
zdot_use_plugin omz:plugins/tmux
```

### OMZ Libraries

```zsh
zdot_use_plugin omz:lib          # Declare OMZ lib spec (libs are lazy-loaded via stubs)
zdot_use_plugin omz:plugins/nvm  # NVM with OMZ integration
```

### Prezto Modules

Access Prezto modules with the `pz:` prefix, or use the convenience wrapper:

```zsh
zdot_use_plugin pz:modules/git        # Load the Prezto git module
zdot_use_plugin pz:modules/syntax-highlighting
zdot_use_plugin pz:modules/autosuggestions

# Convenience wrapper (equivalent to the above)
zdot_use_pz git
zdot_use_pz syntax-highlighting
zdot_use_pz autosuggestions
```

Prezto is cloned automatically (with submodules) on first shell startup.
A minimal `.zpreztorc` stub is created at `${ZDOTDIR:-$HOME}/.zpreztorc` if
none exists, so that Prezto does not auto-load modules — zdot handles module
loading exclusively via `zdot_use_plugin pz:modules/<name>`.

To disable the Prezto bundle entirely:

```zsh
zstyle ':zdot:plugins' pz false
```

## Plugin Management Commands

### List Plugins

```bash
zdot plugin list --declared    # Show plugins declared in config
zdot plugin list --loaded      # Show plugins that were loaded
zdot plugin list --installed  # Show plugins in cache
```

### Update Plugins

```bash
zdot plugin update              # Update all plugins
zdot plugin update Aloxaf/fzf-tab  # Update specific plugin
```

Aliases: `zdot-update`, `zdot-update <plugin>`

### Clean Plugins

```bash
zdot plugin clean --dry-run        # Show what would be removed
zdot plugin clean --remove-unused # Remove unused plugins
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
