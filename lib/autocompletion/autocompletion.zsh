#!/usr/bin/env zsh
# autocomplete: Completion, syntax highlighting, and suggestion plugins

# ============================================================================
# Plugin Configuration
# ============================================================================

_autocomplete_plugins_configure() {
    # Fast-syntax-highlighting
    FAST_WORK_DIR=XDG:fast-syntax-highlighting

    # Zsh-autosuggest
    ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd abbreviations completion)

    # Zsh-abbr
    ABBR_AUTOLOAD=1
    ABBR_SET_EXPANSION_CURSOR=1
    ABBR_SET_LINE_CURSOR=1
    ABBR_GET_AVAILABLE_ABBREVIATION=1
    ABBR_USER_ABBREVIATIONS_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-abbr/user-abbreviations
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

zdot_use_plugin zdharma-continuum/fast-syntax-highlighting defer \
    --name fsh-load --provides fsh-ready \
    --requires autocomplete-loaded

zdot_use_plugin 5A6F65/fast-abbr-highlighting defer \
    --name fast-abbr-load --provides fast-abbr-ready \
    --requires fsh-ready

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
# Post-Load Setup
# ============================================================================

_autocomplete_plugins_post_init() {
    # Fast-syntax-highlighting theme (after plugins load)
    # Configure via: zstyle ':zdot:autocompletion' fsh-theme '/path/to/theme.ini'
    # Set to empty string to disable theme loading entirely.
    if zdot_interactive; then
        local _fsh_default="${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini"
        local _fsh_theme
        zstyle -s ':zdot:autocompletion' fsh-theme _fsh_theme || _fsh_theme="${_fsh_default}"
        if [[ -n "${_fsh_theme}" && -f "${_fsh_theme}" ]]; then
            local _fsh_current="${_fsh_theme:h}/current_theme.zsh"
            if [[ "${_fsh_theme:A}" -nt "${_fsh_current:A}" ]]; then
                zdot_defer -q fast-theme -q "${_fsh_theme}"
            fi
        fi
    fi
}

# ============================================================================
# Module Definition
# ============================================================================

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
