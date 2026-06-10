#!/usr/bin/env zsh
# vim-mode: vi keybindings with cursor + prompt integration
#   (wraps the georgeharker/zsh-vim-mode plugin)
#
# Loads zsh-vim-mode as a zdot module. Configuration is split in two zstyle
# namespaces, both fully overridable:
#
#   :zsh-vim-mode:*   the plugin's own behaviour — cursor, insert keymap,
#                       per-mode indicators, redraw policy (see plugin README)
#   :zdot:vim-mode    this module's knobs — the prompt-integration strategy
#
# Every default below is a backstop (zdot_zstyle_default sets it only when
# unset), so override any of it from a `vim-mode-configure` hook or before
# `zdot_load_module vim-mode`:
#
#   _my_vim_mode() {
#       zstyle ':zsh-vim-mode:'       insert-keymap viins   # conventional vi insert
#       zstyle ':zsh-vim-mode:insert' indicator     '[I]'
#       zstyle ':zdot:vim-mode'       prompt        omz
#   }
#   zdot_register_hook _my_vim_mode interactive --group vim-mode-configure

# Backstop defaults — the plugin reads :zsh-vim-mode:* when _vim_mode_load
# sources it; _vim_mode_prompt reads :zdot:vim-mode after the prompt is ready.
_vim_mode_configure() {
    # Plugin behaviour
    zdot_zstyle_default ':zsh-vim-mode:' set-cursor    yes
    # Insert mode IS the emacs/readline keymap (full editing, live and
    # order-independent); ESC drops into vi normal mode.
    zdot_zstyle_default ':zsh-vim-mode:' insert-keymap emacs
    # Blank while typing; [Normal]/[Visual]/[V-Line] show otherwise.
    zdot_zstyle_default ':zsh-vim-mode:insert' indicator ''

    # Module behaviour: how to keep the indicator live on a mode change.
    #   auto (default) — oh-my-posh if its module is loaded, else prompt-expansion
    #   omp | omz | none
    zdot_zstyle_default ':zdot:vim-mode' prompt auto
}

# Source the plugin (zstyles are resolved by now).
_vim_mode_load() {
    zdot_load_plugin georgeharker/zsh-vim-mode
}

# Keep the indicator live on a mode change. The plugin redraws the prompt
# itself; how the indicator gets refreshed depends on the prompt system:
#
#   omp  oh-my-posh bakes {{ .Env.VIMODE }} at render time, so a bare
#          reset-prompt redraws a stale mode. Refresh VIMODE and re-render omp's
#          own right block (_omp_get_prompt — least-invasive, reads cached
#          state) through the plugin's redraw-hooks seam.
#   omz  prompt-expansion prompts (oh-my-zsh themes, a $PROMPT carrying
#          $(vi_mode_prompt_info)) re-expand on the plugin's own reset-prompt —
#          nothing to wire (the plugin even defaults RPS1 to the indicator when
#          no prompt is set).
#   none no integration.
#
# Runs after prompt-ready so the prompt module is loaded (and, for omp, so this
# overrides oh-my-posh's own empty set_poshcontext rather than being clobbered).
_vim_mode_prompt() {
    local strategy
    zstyle -s ':zdot:vim-mode' prompt strategy || strategy=auto
    if [[ $strategy == auto ]]; then
        # Decide from the loaded module list, not omp's functions: the prompt is
        # deferred, so `${+functions[_omp_get_prompt]}` is timing-dependent.
        # zdot_module_loaded reflects that the module file was sourced (i.e.
        # which prompt is configured), which is true from early startup.
        zdot_module_loaded omp-prompt && strategy=omp || strategy=omz
    fi

    case $strategy in
        omp)
            # Defined here (post-init, after prompt-ready) so this overrides
            # oh-my-posh's own empty set_poshcontext rather than being clobbered
            # by it. The render self-guards on _omp_get_prompt at call time.
            function set_poshcontext() { export VIMODE="$(vi_mode_prompt_info)" }
            function _vim_mode_omp_render() {
                (( ${+functions[_omp_get_prompt]} )) || return
                set_poshcontext
                RPROMPT=$(_omp_get_prompt right)
            }
            zdot_zstyle_default ':zsh-vim-mode:' redraw-hooks _vim_mode_omp_render
            ;;
        omz|none) ;;   # the plugin's own reset-prompt covers prompt-expansion prompts
    esac
}

# Declare the plugin for the zdot plugin system to clone/update. Loaded later
# from _vim_mode_load so vim-mode-configure hooks set zstyles before it loads.
zdot_use_plugin georgeharker/zsh-vim-mode

# Interactive only (zle). --auto-configure-group makes _vim_mode_configure the
# consumer of the vim-mode-configure user-extension group.
zdot_define_module vim-mode \
    --configure _vim_mode_configure \
    --load _vim_mode_load \
    --post-init _vim_mode_prompt \
    --auto-configure-group \
    --context interactive \
    --requires plugins-cloned \
    --post-init-requires prompt-ready \
    --post-init-context interactive
