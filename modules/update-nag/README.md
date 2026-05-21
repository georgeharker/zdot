# update-nag — package update reminders

Loads the [`madisonrickert/zsh-pkg-update-nag`](https://github.com/madisonrickert/zsh-pkg-update-nag)
plugin (by default) at shell start. The plugin checks whether common package
managers (Homebrew, apt, npm, etc.) have pending updates and prints a reminder
nag if they do. Checks run in the background so they do not block the
interactive prompt.

## Requirements

- XDG base directories set (`$XDG_CONFIG_HOME`).

## What it does

1. Resolves the plugin spec from `zstyle ':zdot:update-nag' plugin` (default
   `madisonrickert/zsh-pkg-update-nag`) and declares it via `zdot_use_plugin`
   so zdot downloads/manages the plugin.
2. In the configure phase, sets `ZSH_PKG_UPDATE_NAG_BACKGROUND=1` to run
   update checks in the background.
3. In the load phase, loads the plugin via `zdot_load_plugin`.

## Configuration

### Plugin source

Override the plugin repo via zstyle:

```zsh
zstyle ':zdot:update-nag' plugin 'fork/zsh-pkg-update-nag'
zdot_load_module update-nag
```

Because `zdot_use_plugin` runs at module-source time, the zstyle must be set
before `zdot_load_module update-nag`. Alternatively, register a before-module
callback so the override lives next to the module config:

```zsh
zdot_before_module update-nag --fn _my_update_nag_config
_my_update_nag_config() {
    zstyle ':zdot:update-nag' plugin 'fork/zsh-pkg-update-nag'
}
```

### Plugin env vars

The plugin reads its own configuration file automatically:

```
${XDG_CONFIG_HOME}/zsh-pkg-update-nag/config.zsh
```

To set `ZSH_PKG_UPDATE_NAG_*` env vars from your own module, attach a hook to
the `update-nag-configure` group (created by `--auto-configure-group`):

```zsh
zdot_register_hook _my_nag_env interactive \
    --group update-nag-configure
_my_nag_env() {
    export ZSH_PKG_UPDATE_NAG_INTERVAL=86400
}
```

See the [zsh-pkg-update-nag documentation](https://github.com/madisonrickert/zsh-pkg-update-nag)
for available settings.

## Provides

- Phase: `update-nag-configured` (configure phase)
- Phase: `update-nag-loaded` (load phase)
- Extension group: `update-nag-configure`
