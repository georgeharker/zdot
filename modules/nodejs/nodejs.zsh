#!/usr/bin/env zsh
# nodejs: where `node` comes from (nvm or the system), plus the OMZ npm plugin
#
# zstyle ':zdot:nodejs' provider <nvm|nvm-lazy|system>
#
#   nvm (default)  nvm's current version, at no startup cost: nvm keeps
#                  $NVM_DIR/current pointing at the version `nvm use` last
#                  selected (NVM_SYMLINK_CURRENT=true, exported here), and
#                  $NVM_DIR/current/bin goes first on PATH. nvm itself is never
#                  sourced at startup; `nvm` loads on first use. If the link is
#                  missing or broken it's created once, by running nvm
#                  (`nvm use default`). `nvm use X` then applies to every new
#                  shell, not just the one you ran it in.
#   nvm-lazy       The classic setup: the OMZ nvm plugin's lazy stubs (nvm,
#                  node, npm, npx, pnpm, yarn, corepack, plus lazy-cmd), and
#                  `nvm use node` per shell: deferred in interactive shells,
#                  eager (~500 ms) in noninteractive ones and under $NVIM.
#   system         Whatever node is on PATH (brew on macOS, apt on Debian...).
#                  PATH is left alone; `nvm` still loads on demand if installed.
#
# Without nvm installed, every provider behaves like system.
#
# zstyle ':zdot:nodejs' lazy-cmd <cmd...>   nvm-lazy only: extra commands
#                                           whose first use loads nvm

# Both plugins are declared (cloned); _node_load loads the nvm one only for
# nvm-lazy. Its lazy stubs would shadow the node already on PATH in the other
# modes, and without lazy mode it sources nvm.sh at startup.
zdot_use_plugin omz:plugins/npm
zdot_use_plugin omz:plugins/nvm

# ============================================================================
# Configuration
# ============================================================================

_node_configure() {
    export NVM_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvm"

    local provider
    zdot_zstyle_get ':zdot:nodejs' provider provider nvm
    case "$provider" in
        nvm|nvm-lazy|system) ;;
        *) zdot_warn "nodejs: unknown provider '$provider' (nvm, nvm-lazy, system); using system"
           provider=system ;;
    esac
    typeset -g _ZDOT_NODE_PROVIDER="$provider"

    [[ -f "$NVM_DIR/nvm.sh" ]] || return 0
    # Compiled by zdot alongside the npm plugin (loaded in every mode).
    zdot_plugin_compile_extra omz:plugins/npm "$NVM_DIR/nvm.sh"

    case "$provider" in
        nvm)      _nvm_current_setup; _nvm_lazy_define ;;
        system)   _nvm_lazy_define ;;
        nvm-lazy) _nvm_omz_lazy_configure ;;
    esac
}

# _nvm_current_setup — put $NVM_DIR/current/bin first on PATH, creating the
# link (once, via nvm) if it's missing or no longer points at a node.
_nvm_current_setup() {
    export NVM_SYMLINK_CURRENT=true
    local current="$NVM_DIR/current"
    if [[ ! -x "$current/bin/node" ]]; then
        # One-time: let nvm resolve the default alias (node, lts/*, 22, ...)
        # and write the link. Subshell: keeps nvm's functions and PATH edits
        # out of this shell.
        ( source "$NVM_DIR/nvm.sh" --no-use && nvm use default --silent ) >/dev/null 2>&1
    fi
    [[ -x "$current/bin/node" ]] || return 0
    path=("$current/bin" ${path:#$current/bin})
}

# _nvm_lazy_define — `nvm` on demand (nvm and system providers). Unlike the
# OMZ nvm plugin's lazy mode, this stubs only `nvm`, not node/npm/npx/…,
# which would shadow the node already on PATH and load nvm on the first
# `node` call.
_nvm_lazy_define() {
    (( ${+functions[nvm]} )) || functions[nvm]='_nvm_lazy_load "$@"'
}

# _nvm_lazy_load <args> — first `nvm` call: source nvm without switching
# versions (PATH already has the right node), then run the real `nvm`.
_nvm_lazy_load() {
    unfunction nvm
    source "$NVM_DIR/nvm.sh" --no-use
    nvm "$@"
}

# _nvm_completion — nvm/system providers (nvm-lazy: the OMZ plugin does it).
# Runs in _completions_finalize, before zdot's compinit.
#
# nvm ships only bash completion. In zsh its script runs compinit unless
# `compinit` is already defined, then bashcompinit, then `complete`. Declaring
# compinit (not running it) skips the first step; zdot runs compinit later.
# `complete`'s compdef is queued and replayed after compinit.
#
# Depends on: nvm testing `command -v compinit` (not whether it ran), and
# zdot's compdef queue preserving arguments with spaces.
_nvm_completion() {
    [[ "$_ZDOT_NODE_PROVIDER" == (nvm|system) ]] || return 0
    [[ -f "$NVM_DIR/bash_completion" ]] || return 0
    autoload -Uz compinit   # declared, not run
    source "$NVM_DIR/bash_completion"
}
zdot_register_completion_live _nvm_completion

# _nvm_omz_lazy_configure — nvm-lazy: zstyles for the OMZ nvm plugin.
# Noninteractive shells (and Neovim terminals) load nvm eagerly so it's
# available synchronously; interactive ones get the lazy stubs.
_nvm_omz_lazy_configure() {
    if ! zdot_interactive || [[ -n "$NVIM" ]]; then
        zstyle ':omz:plugins:nvm' lazy no
    else
        zstyle ':omz:plugins:nvm' lazy yes
    fi
    zstyle ':omz:plugins:nvm' autoload no

    # Extra stubs beyond the plugin's own (nvm node npm npx pnpm pnpx yarn
    # corepack): only for commands installed inside nvm's prefix.
    local -a lazy_cmds
    zdot_zstyle_get -a ':zdot:nodejs' lazy-cmd lazy_cmds
    zstyle ':omz:plugins:nvm' lazy-cmd "${lazy_cmds[@]}"
}

# ============================================================================
# Load
# ============================================================================

_node_load() {
    zdot_load_plugin omz:plugins/npm
    [[ "$_ZDOT_NODE_PROVIDER" == nvm-lazy ]] && zdot_load_plugin omz:plugins/nvm
    return 0
}

# ============================================================================
# nvm-lazy: per-shell `nvm use`
# ============================================================================

_nvm_interactive_init() {
    [[ "$_ZDOT_NODE_PROVIDER" == nvm-lazy ]] || return 0
    (( ${+functions[nvm]} )) || return 0
    # -q suppresses precmd hooks and zle reset-prompt after the deferred call,
    # preventing oh-my-posh's built-in newline in PS1 from producing a spurious
    # blank line before the next prompt.
    zdot_defer_until -q 1 nvm use node --silent
}

_nvm_noninteractive_init() {
    [[ "$_ZDOT_NODE_PROVIDER" == nvm-lazy ]] || return 0
    (( ${+functions[nvm]} )) || return 0
    nvm use node --silent >/dev/null
}

# ============================================================================
# Module Definition
# ============================================================================

# --load (not --load-plugins): which OMZ plugins load depends on the provider.
#   That forgoes --auto-bundle-deps, so the same wiring is declared here:
#   the omz-plugins group, and soft ordering after the OMZ bundle and plugin
#   clones (soft, so the module still loads when OMZ isn't in use).
# --provides-tool nvm: consumers using --requires-tool nvm order after this.
zdot_define_module node \
    --configure _node_configure \
    --load _node_load \
    --group omz-plugins \
    --after omz-bundle-initialized plugins-cloned \
    --auto-configure-group \
    --provides-tool nvm \
    --interactive-init _nvm_interactive_init \
    --noninteractive-init _nvm_noninteractive_init
