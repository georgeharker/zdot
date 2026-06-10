# vim-mode — vi keybindings with cursor + prompt integration

Loads [georgeharker/zsh-vim-mode](https://github.com/georgeharker/zsh-vim-mode)
as a zdot module: vi command / insert / visual modes, a per-mode cursor and
prompt indicator, and a mode indicator that stays live across both oh-my-posh
and prompt-expansion (oh-my-zsh) prompts.

```zsh
zdot_load_module vim-mode
```

## Configuration

Everything is `zstyle`. The plugin's own behaviour lives under `:zsh-vim-mode:*`
(see the [plugin README](https://github.com/georgeharker/zsh-vim-mode#configuration));
this module adds `:zdot:vim-mode`. Every default below is a **backstop**
(applied only when unset), so override from a `vim-mode-configure` hook or
before `zdot_load_module vim-mode`.

### Module defaults (overridable)

| style | default | meaning |
|-------|---------|---------|
| `:zsh-vim-mode: set-cursor` | `yes` | change the cursor shape per mode |
| `:zsh-vim-mode: insert-keymap` | `emacs` | insert mode is the emacs/readline keymap; ESC enters vi normal |
| `:zsh-vim-mode:insert indicator` | `''` | blank indicator while typing |
| `:zdot:vim-mode prompt` | `auto` | prompt-integration strategy (below) |

### `:zdot:vim-mode prompt`

- `auto` *(default)* — `omp` if the `omp-prompt` module is loaded
  (`zdot_module_loaded`), else `omz`
- `omp` — refresh `$VIMODE` and re-render oh-my-posh's right block on each mode
  change (via the plugin's `redraw-hooks`)
- `omz` — rely on the plugin's `reset-prompt` re-expanding `$(vi_mode_prompt_info)`
- `none` — no prompt integration

The omp wiring runs after `prompt-ready`, and detection uses the loaded **module
list** (not oh-my-posh's functions), so it's correct whether the prompt is eager
or deferred.

### Override example

```zsh
_my_vim_mode() {
    zstyle ':zsh-vim-mode:'       insert-keymap viins      # conventional vi insert
    zstyle ':zsh-vim-mode:insert' indicator     '[I]'
    zstyle ':zsh-vim-mode:normal'  cursor       block
}
zdot_register_hook _my_vim_mode interactive --group vim-mode-configure
```

## Phases

- `_vim_mode_configure` — seeds the backstop zstyles (consumer of the
  `vim-mode-configure` group).
- `_vim_mode_load` — `zdot_load_plugin georgeharker/zsh-vim-mode` (requires
  `plugins-cloned`).
- `_vim_mode_prompt` — wires the prompt integration (requires `prompt-ready`).
