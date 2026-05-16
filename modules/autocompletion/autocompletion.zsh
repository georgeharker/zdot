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
zdot_use_plugin olets/zsh-abbr defer \
    --name zsh-abbr-load --provides abbr-ready \
    --requires autocomplete-loaded

zdot_use_plugin zsh-users/zsh-autosuggestions defer \
    --name autosuggest-load --provides autosuggest-ready \
    --requires autocomplete-loaded \
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
    --post-init-requires autosuggest-abbr-ready \
    --post-init-context interactive

# ============================================================================
# Compinit (deferred, after all deferred plugins)
# ============================================================================

zdot_register_hook zdot_compinit_defer interactive \
    --name compinit-defer --deferred \
    --requires autosuggest-abbr-ready --provides compinit-done
