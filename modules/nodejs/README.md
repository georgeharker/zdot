# lib/nodejs — Node.js / nvm Module

Integrates [nvm](https://github.com/nvm-sh/nvm) and the OMZ `npm` plugin into
the shell via the oh-my-zsh plugin bundle.

## Why nvm loading is deferred

nvm is slow to initialise. Sourcing `nvm.sh` at shell startup performs file I/O,
sets up shell functions, and may invoke `node` to resolve the active version.
On a typical setup this adds **200–500 ms** to every shell start — noticeable in
interactive terminals, and expensive in noninteractive shells (editor terminals,
tmux panes, scripts).

This module uses two strategies to avoid that cost:

### Lazy loading (interactive shells)

In interactive shells the OMZ nvm plugin's `lazy yes` mode is enabled. nvm is
**not** sourced at startup. Instead a set of stub functions are installed for
each name in the `lazy-cmd` list; the first call to any stub transparently loads
nvm and then runs the real command.

This means the common case — opening a terminal and running one of your usual
Node-backed tools — incurs the nvm init cost exactly once per session, only when
you actually need it, and not at all if you never run a Node command.

### Deferred `nvm use` (interactive shells)

After nvm is loaded, `nvm use node` selects the default Node version. In
interactive shells this is run via `zdot_defer_until` with the `-q` flag so it
executes after the first prompt has rendered. The `-q` flag suppresses `precmd`
hooks and `zle reset-prompt` after the deferred call, which prevents a spurious
blank line from appearing before the next prompt when oh-my-posh is active.

### Noninteractive shells

In noninteractive shells (and when `$NVIM` is set — i.e. a Neovim terminal
buffer), lazy loading is disabled (`lazy no`) so that nvm is available
synchronously. `nvm use node` is called immediately and silently. This is
necessary because noninteractive shells don't render a prompt, so there is no
safe defer point.

---

## Configuration

### `lazy-cmd` list

The list of command names that trigger nvm lazy-loading is read from a zstyle,
with a built-in default:

| zstyle | Default | Purpose |
|---|---|---|
| `':zdot:nodejs' lazy-cmd` | `()` | Extra commands whose first invocation triggers nvm load |

The OMZ plugin always stubs `nvm node npm npx pnpm pnpx yarn corepack`; this
list adds to those. Only commands installed inside nvm's prefix need a stub:
bun globals (see the `bun` module) and native installers are on `PATH` without
nvm, and `#!/usr/bin/env node` scripts use whichever `node` is on `PATH`.
Override it in a `node-configure` group hook (see below).

---

## Extension point — `node-configure` group

A `node-configure` hook group runs before `_node_configure`. Register a hook
into this group to set `':zdot:nodejs'` zstyles before the module reads them:

```zsh
_my_node_configure() {
    # Stub tools installed with npm inside nvm's prefix
    zstyle ':zdot:nodejs' lazy-cmd nx my-npm-tool
}

zdot_register_hook _my_node_configure interactive noninteractive \
    --group node-configure
```

---

## NVM directory

nvm is expected at `$XDG_DATA_HOME/nvm` (typically `~/.local/share/nvm`).
The module pre-compiles `nvm.sh` to a `.zwc` bytecode file on first load (or
when `nvm.sh` is newer than its compiled form), reducing subsequent source time.

---

## Provided tools

| Provides | Description |
|---|---|
| `nvm` (tool) | Declared as a provided tool so other modules can express `--requires-tool nvm` |
