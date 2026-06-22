#!/usr/bin/env zsh
# autocomplete: Completion and suggestion plugins

# ============================================================================
# Plugin Configuration
# ============================================================================

_autocomplete_plugins_configure() {
    # Zsh-autosuggest
    # Prefer the contextual-history-aware port of match_prev_cmd when the
    # history module is loaded with per-dir enabled (which is what causes
    # georgeharker/zsh-contextual-history to actually load). It falls back to
    # the upstream strategy behaviour when local-history mode is off, so it is
    # a safe drop-in.
    local _autosuggest_match_strategy=match_prev_cmd
    if zdot_module_loaded history && zstyle -T ':zdot:history' per-dir; then
        _autosuggest_match_strategy=contextual_match_prev_cmd
    fi
    ZSH_AUTOSUGGEST_STRATEGY=("$_autosuggest_match_strategy" abbreviations completion)  # shuck: ignore=C001
    unset _autosuggest_match_strategy

    # Zsh-abbr
    ABBR_AUTOLOAD=1  # shuck: ignore=C001
    ABBR_SET_EXPANSION_CURSOR=1  # shuck: ignore=C001
    ABBR_SET_LINE_CURSOR=1  # shuck: ignore=C001
    ABBR_GET_AVAILABLE_ABBREVIATION=1  # shuck: ignore=C001
    ABBR_USER_ABBREVIATIONS_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-abbr/user-abbreviations  # shuck: ignore=C001
}

# ============================================================================
# Plugin Declarations
# ============================================================================

# OMZ plugins (eager)
zdot_use_plugin omz:plugins/zoxide defer

# Deferred plugins (bespoke dependency DAG)
# Recommended interactive load order is fzf-tab -> abbr -> autosuggest. It is
# expressed with SOFT --after edges (not --requires): each plugin yields to the
# prior one IF it is active, but still loads if it is absent/disabled, so the
# chain composes and degrades gracefully. The only HARD --requires here are
# genuine dependencies (the module gate, and the abbreviations strategy needing
# autosuggestions loaded).
zdot_use_plugin olets/zsh-abbr defer \
    --name zsh-abbr-load --provides abbr-ready \
    --requires autocomplete-loaded \
    --after fzf-tab-loaded

zdot_use_plugin zsh-users/zsh-autosuggestions defer \
    --name autosuggest-load --provides autosuggest-ready \
    --requires autocomplete-loaded \
    --after abbr-ready fzf-tab-loaded \
    --context interactive

zdot_use_plugin olets/zsh-autosuggestions-abbreviations-strategy defer \
    --name autosuggest-abbr-load --provides autosuggest-abbr-ready \
    --requires autosuggest-ready \
    --context interactive

# ============================================================================
# Eager Load (OMZ plugins)
# ============================================================================

_autocomplete_plugins_load() {
    zdot_load_plugin omz:plugins/zoxide
}

# ============================================================================
# Module Definition
# ============================================================================

_autocomplete_plugins_post_init() { :; }

zdot_define_module autocomplete \
    --configure _autocomplete_plugins_configure \
    --load _autocomplete_plugins_load \
    --post-init _autocomplete_plugins_post_init \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized \
    --auto-configure-group \
    --post-init-requires autosuggest-abbr-ready \
    --post-init-context interactive

# ============================================================================
# Autosuggestions activation
# ============================================================================
#
# In the deferred setup, zsh-autosuggestions' own `_zsh_autosuggest_start` precmd
# hook never fires during the FIRST prompt — the zsh-defer drain runs after
# prompt-1's precmd and itself fires no precmd — so `self-insert` et al. are not
# wrapped until prompt 2 ("suggestions dead at first prompt"). We fix the TIMING
# by firing _zsh_autosuggest_start ourselves, once, during the drain.
#
# Gated only on autosuggest-abbr-ready (i.e. autosuggest is loaded). Ordering
# relative to the widget-redefiners (zsh-abbr, fzf-tab) is NOT required: a source
# sweep confirmed every widget-wrapping plugin in this setup CALLS THROUGH to the
# prior implementation, so the chain stays intact regardless of load/wrap order,
# and autosuggest re-wraps on every precmd thereafter anyway. (If a future plugin
# ever redefines a wrapped widget WITHOUT calling through, suggestions would die
# on that widget until the next precmd — that's the plugin's bug to fix, or the
# reason to reintroduce an explicit "after the widget-redefiners" ordering gate.)
#
# Autosuggest-specific, so it lives in THIS module; compinit is launched
# separately from the completions module.
#
# Soft --after compinit-done: the autosuggest `completion` strategy queries the
# completion system, so it only yields suggestions once compinit has run. That
# query is lazy (per keystroke at the prompt, after the drain), so it cannot go
# on the autosuggest LOAD — compinit is deliberately ordered AFTER the load (so
# autosuggest's fpath/completions are picked up), and a load-time edge would
# close that cycle. Activation is the right seam: it runs after compinit when
# the completions module provides compinit-done, and still fires if it doesn't
# (soft, no gate).
_autocomplete_autosuggest_start() {
    (( ${+functions[_zsh_autosuggest_start]} )) && _zsh_autosuggest_start
}

zdot_register_hook _autocomplete_autosuggest_start interactive \
    --deferred \
    --requires autosuggest-abbr-ready \
    --after compinit-done \
    --provides autosuggest-started
