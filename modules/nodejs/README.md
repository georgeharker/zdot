# modules/nodejs — Node.js / nvm Module

Decides where `node` comes from, either nvm or the system, and loads the OMZ
`npm` plugin (completions, aliases).

## Providers

```zsh
zstyle ':zdot:nodejs' provider nvm        # default
zstyle ':zdot:nodejs' provider nvm-lazy   # the classic OMZ lazy setup
zstyle ':zdot:nodejs' provider system
```

| provider | `node` on `PATH` | startup cost |
|---|---|---|
| `nvm` (default) | nvm's current version: `$NVM_DIR/current/bin`, first | ~0 (no nvm at startup) |
| `nvm-lazy` | per shell: `nvm use node` | interactive: deferred; noninteractive: ~500 ms |
| `system` | whatever is already on `PATH`: Homebrew on macOS, apt on Debian, … | 0 |

In `nvm` and `system`, `nvm` itself loads the first time you run it, and the
OMZ nvm plugin isn't loaded at all. If nvm isn't installed, every provider
behaves like `system`.

On macOS Homebrew's `node` is easy to keep current, so `system` is a sound
choice there. Debian's packaged node is usually far behind, which is why nvm is
the default.

### How `nvm` mode avoids loading nvm

nvm can keep a symlink, `$NVM_DIR/current`, pointing at the version that
`nvm use` last selected. It does this whenever `NVM_SYMLINK_CURRENT=true`. The
module exports that variable and puts `$NVM_DIR/current/bin` first on `PATH`,
so every shell (interactive or not, and services that copy their `PATH` from a
shell) gets nvm's node without sourcing `nvm.sh` or running `nvm use`. That
used to cost about 500 ms in every noninteractive shell.

If the link is missing, or no longer points at an installed node, the module
runs nvm once (`nvm use default`) to create it. nvm resolves the default alias
itself (`node`, `lts/*`, `22`, …), so there's no separate resolution logic to
keep in step with nvm.

**`nvm use` is now global.** It moves the `current` link, so the version you
pick applies to every new shell and to services started afterwards, not just
the shell you ran it in. The shell you ran it in also switches straight away,
as usual.

### The lazy `nvm`

`nvm` is a small function that, on first use, sources `nvm.sh --no-use` (so
`PATH` keeps the node already on it), then runs the real `nvm`. Unlike the OMZ nvm plugin's lazy mode, it stubs only `nvm`.
The OMZ plugin also stubs `node`, `npm`, `npx`, `pnpm`, `yarn` and `corepack`,
which would hide the node already on `PATH` and load nvm on the first `node`
call. The OMZ nvm plugin isn't loaded.

**Completion.** nvm ships only bash completion. In `nvm` and `system` modes it
is loaded via `zdot_register_completion_live`, with `compinit` declared first
so nvm's script doesn't run it. In `nvm-lazy` mode the OMZ plugin handles it.

### `nvm-lazy`: the classic setup

For anyone who wants nvm per shell, exactly as before:

- **Interactive shells:** the OMZ nvm plugin's lazy stubs (`nvm`, `node`,
  `npm`, `npx`, `pnpm`, `yarn`, `corepack`, plus any `lazy-cmd` names). The
  first use loads nvm. `nvm use node` runs after the first prompt (deferred,
  with `-q` so oh-my-posh doesn't print a stray blank line).
- **Noninteractive shells and Neovim terminals (`$NVIM`):** nvm loads eagerly
  and `nvm use node` runs immediately, so `node` is there synchronously. This
  costs about 500 ms per shell.
- `nvm use X` applies only to the shell you run it in.

| zstyle | Default | Purpose |
|---|---|---|
| `':zdot:nodejs' lazy-cmd` | `()` | `nvm-lazy` only: extra commands whose first use loads nvm. Only needed for tools installed inside nvm's prefix |

---

## Extension point — `node-configure` group

A `node-configure` hook group runs before `_node_configure`. Register a hook
into this group to set `':zdot:nodejs'` zstyles before the module reads them,
or set them directly in `.zshrc` before the module loads:

```zsh
zdot_before_module nodejs --cmd zstyle ':zdot:nodejs' provider system
```

---

## NVM directory

nvm is expected at `$XDG_DATA_HOME/nvm` (typically `~/.local/share/nvm`).
`nvm.sh` goes on zdot's compile list (`zdot_plugin_compile_extra`, alongside
the npm plugin), so zdot keeps a `.zwc` of it up to date, which speeds up the
lazy load.

---

## Provided tools

| Provides | Description |
|---|---|
| `nvm` (tool) | Declared as a provided tool so other modules can express `--requires-tool nvm` |

## Tests

`zsh -f tests/test_nodejs.zsh`: all three providers, link creation and
repair, `PATH` placement, the lazy `nvm`, which plugins load, and the
`nvm-lazy` init hooks. It uses a fake nvm in a throwaway `HOME`.
