#!/usr/bin/env zsh
# syntax-highlight: Syntax highlighting plugins
#
# Loads fast-syntax-highlighting and fast-abbr-highlighting as deferred plugins.
# Orders after the autocompletion module (abbr-ready) and a prompt module
# (prompt-ready) when they're loaded, but works standalone without either — see
# the --requires-optional edges below.
#
# Configuration:
#   zstyle ':zdot:syntax-highlight' fsh-theme '/path/to/theme.ini'
#   Set to empty string to disable theme loading entirely.

# ============================================================================
# Plugin Configuration
# ============================================================================

_syntax_highlight_configure() {
    FAST_WORK_DIR=XDG:fast-syntax-highlighting  # shuck: ignore=C001
}

# ============================================================================
# Plugin Declarations
# ============================================================================

# Deferred plugins (bespoke dependency DAG).
#
# Cross-module edges use --requires-optional, not --requires: this module must
# load in a standalone config that doesn't pull in a prompt module or the
# autocompletion module. --requires-optional keeps the ordering (and deferral)
# when the provider is present, but drops the edge — the plugin still loads —
# when it isn't, instead of aborting the plan build.
#   prompt-ready : fsh wraps ZLE widgets, so it should come after the prompt sets
#                  up — but it needs no prompt to function (pure ordering).
#   abbr-ready   : fast-abbr-highlighting highlights zsh-abbr abbreviations, so it
#                  orders after abbr when present; without abbr it loads idle
#                  (nothing to highlight), which keeps fast-abbr-ready provided for
#                  the module post-init below.
zdot_use_plugin zdharma-continuum/fast-syntax-highlighting defer \
    --name fsh-load --provides fsh-ready \
    --requires syntax-highlight-loaded \
    --requires-optional prompt-ready

zdot_use_plugin 5A6F65/fast-abbr-highlighting defer \
    --name fast-abbr-load --provides fast-abbr-ready \
    --requires fsh-ready \
    --requires-optional abbr-ready

# ============================================================================
# Post-Load Setup
# ============================================================================

_syntax_highlight_post_init() {
    local _fsh_default="${XDG_CONFIG_HOME:-${HOME}/.config}/fast-syntax-highlighting/tokyonight.ini"
    local _fsh_theme
    zstyle -s ':zdot:syntax-highlight' fsh-theme _fsh_theme || _fsh_theme="${_fsh_default}"
    if [[ -n "${_fsh_theme}" && -f "${_fsh_theme}" ]]; then
        local _fsh_current="${_fsh_theme:h}/current_theme.zsh"
        if [[ "${_fsh_theme:A}" -nt "${_fsh_current:A}" ]]; then
            zdot_defer -q fast-theme -q "${_fsh_theme}"
        fi
    fi
}

# ============================================================================
# Module Definition
# ============================================================================

zdot_define_module syntax-highlight \
    --configure _syntax_highlight_configure \
    --post-init _syntax_highlight_post_init \
    --requires plugins-cloned \
    --auto-configure-group \
    --post-init-requires fast-abbr-ready \
    --post-init-context interactive
