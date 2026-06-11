# zdot Documentation

The docs are organized as a journey: each stage builds on the one before.
Start where your needs are.

## 1. Get set up

| Document | What it covers |
|----------|----------------|
| [Project README → Quick Start](../README.md#quick-start) | Standalone install: clone, source, first module list |
| [Quickstart: dotfiler + zdot](quickstart-dotfiler.md) | The recommended full setup: dotfiles repo, symlink tree, self-updates, new-machine bootstrap |

## 2. Use plugins and configure what ships

| Document | What it covers |
|----------|----------------|
| [Using Plugins](using-plugins.md) | Declaring plugins (GitHub, OMZ, Prezto), deferred loading, configuring shipped modules, plugin updates |
| [Module catalog](modules.md) | Every built-in module: what it does, provides, requires, and its zstyle keys |

## 3. Write your own modules

| Document | What it covers |
|----------|----------------|
| [Module Writer's Guide](module-guide.md) | From a 3-line module to multi-phase plugin lifecycles: `zdot_simple_hook`, `zdot_define_module`, manual hooks, groups, extension points |

## 4. Get more complex

| Document | What it covers |
|----------|----------------|
| [Advanced Usage](advanced.md) | Shell contexts, the `.zshenv`-as-`.zshrc` pattern, per-machine variants, controlling deferred execution, writing a bundle handler |

## 5. Reference

| Document | What it covers |
|----------|----------------|
| [API Reference](api-reference.md) | Every public function with full flag tables |
| [zstyle Reference](zstyle-reference.md) | Every configuration option, grouped by subsystem |
| [CLI Reference](commands.md) | The `zdot` command: every noun and verb |
| [compinit](compinit.md) | Completion-system controls: compaudit, cached dumps, forced refresh |

## 6. Internals

For developers working on zdot itself:

| Document | What it covers |
|----------|----------------|
| [Implementation Guide](implementation.md) | Architecture, data structures, dependency resolution, force-deferral, caching system |
| [Plugin Implementation](plugin-implementation.md) | Plugin manager internals, bundle registry, compdef queue, compinit flow |
| [design/](design/) | Working design notes and historical decision records |
