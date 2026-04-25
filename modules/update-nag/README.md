# update-nag — package update reminders

Loads the [`madisonrickert/zsh-pkg-update-nag`](https://github.com/madisonrickert/zsh-pkg-update-nag)
plugin at shell start. The plugin checks whether common package managers
(Homebrew, apt, npm, etc.) have pending updates and prints a reminder nag if
they do. Checks run in the background so they do not block the interactive
prompt.

## Requirements

- XDG base directories set (`$XDG_CONFIG_HOME`) — the module registers via
  `zdot_simple_hook` which requires XDG paths to be available before it runs.

## What it does

1. Declares a dependency on `madisonrickert/zsh-pkg-update-nag` via
   `zdot_use_plugin` so zdot downloads/manages the plugin.
2. Sets `ZSH_PKG_UPDATE_NAG_BACKGROUND=1` to run update checks in the
   background, avoiding prompt delay.
3. Loads the plugin via `zdot_load_plugin`.

## Configuration

The plugin reads its own configuration file automatically:

```
${XDG_CONFIG_HOME}/zsh-pkg-update-nag/config.zsh
```

Create this file to control which package managers are checked, nag
frequency, and other plugin options. See the
[zsh-pkg-update-nag documentation](https://github.com/madisonrickert/zsh-pkg-update-nag)
for available settings.

## Provides

- Phase: `update_nag-ready` (via `zdot_simple_hook`)
