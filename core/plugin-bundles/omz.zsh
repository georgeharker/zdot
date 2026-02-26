#!/usr/bin/env zsh
# core/plugin-bundles/omz.zsh: OMZ plugin bundle handler
# Provides:
#   - ZSH_CUSTOM / ZSH_CACHE_DIR setup
#   - OMZ self-update check
#   - OMZ-specific compdump bundle stamp (git rev override)
#   - OMZ lib loading
#   - OMZ plugin loading
#   - Lazy-loaded OMZ lib stubs
#
# Shared compinit machinery (compdef queue, two-phase defer, precmd hook,
# compdump path, metadata, recompile) lives in core/compinit.zsh.
# SHORT_HOST detection lives in core/utils.zsh.

# ============================================================================
# Early Setup: Clone OMZ if enabled
# ============================================================================

local _zdot_omz_enabled
if zstyle -T ':zdot:plugins' omz; then
    _zdot_omz_enabled=yes
else
    _zdot_omz_enabled=no
fi

if [[ "$_zdot_omz_enabled" == yes ]]; then
    # Clone OMZ using plugin mechanism
    zdot_plugin_clone ohmyzsh/ohmyzsh
fi

# ============================================================================
# Init and Helpers
# ============================================================================

0=${(%):-%N}

##? Check a string for case-insensitive "true" value (1,y,yes,t,true,on).
is-true() {
    [[ -n "$1" && "$1:l" == (1|y(es|)|t(rue|)|on) ]]
}

typeset -gU fpath

autoload -Uz is-at-least

# ============================================================================
# OMZ Self-Update Check
# ============================================================================

zdot_omz_check_for_upgrade() {
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    [[ -f "$cache/tools/check_for_upgrade.sh" ]] && source "$cache/tools/check_for_upgrade.sh"
}

# ============================================================================
# Theme During Precmd (like antidote's set-omz-theme-during-precmd)
# Only loads theme if ZSH_THEME is set
# ============================================================================

zdot_load_omz_theme() {
    local theme_name="${1:-$ZSH_THEME}"
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    local custom="$ZSH_CUSTOM"

    local theme_file

    # Search order mirrors use-omz.zsh:
    #   1. $ZSH_CUSTOM (flat)
    #   2. $ZSH_CUSTOM/themes
    #   3. $ZSH/themes
    if [[ -f "$custom/$theme_name.zsh-theme" ]]; then
        theme_file="$custom/$theme_name.zsh-theme"
    elif [[ -f "$custom/themes/$theme_name.zsh-theme" ]]; then
        theme_file="$custom/themes/$theme_name.zsh-theme"
    elif [[ -f "$cache/themes/$theme_name.zsh-theme" ]]; then
        theme_file="$cache/themes/$theme_name.zsh-theme"
    fi

    if [[ -n "$theme_file" ]]; then
        source "$theme_file"
        _ZDOT_THEME_LOADED=1
    else
        print -u2 "[omz] Theme '$theme_name' not found."
    fi
}

zdot_set_theme_during_precmd() {
    # Self-remove from precmd hook immediately (mirrors use-omz.zsh behaviour)
    autoload -Uz add-zsh-hook
    add-zsh-hook -d precmd zdot_omz_theme_hook

    [[ -n "$ZSH_THEME" ]] || return 0

    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"

    local -A aliases_pre
    local key
    for key in 'ls'; do
        [[ -n "${aliases[$key]:-}" ]] && aliases_pre[$key]=$aliases[$key]
    done

    # async_prompt must be loaded before theme libs (mirrors use-omz.zsh behaviour)
    [[ "${+functions[_omz_register_handler]}" -gt 0 ]] || source "$cache/lib/async_prompt.zsh" 2>/dev/null

    [[ -n "${FX:-}" ]] && [[ -n "${FG:-}" ]] && [[ -n "${BG:-}" ]] || source "$cache/lib/spectrum.zsh" 2>/dev/null
    [[ "${+functions[colors]}" -gt 0 ]] &&
        [[ -n "${ZSH_THEME_GIT_PROMPT_PREFIX:-}" ]] || source "$cache/lib/theme-and-appearance.zsh" 2>/dev/null
    [[ "${+functions[VCS_INFO_formats]}" -gt 0 ]] || source "$cache/lib/vcs_info.zsh" 2>/dev/null

    zdot_load_omz_theme "$ZSH_THEME"

    for key in ${(k)aliases_pre}; do
        aliases[$key]=$aliases_pre[$key]
    done

    if [[ $_ZDOT_THEME_LOADED -eq 1 ]] && typeset -f theme_precmd > /dev/null 2>&1; then
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd theme_precmd
    fi
}

# Hook to register: runs during precmd to load OMZ theme if ZSH_THEME is set
# Only runs in interactive shells, depends on plugins-loaded
zdot_omz_theme_hook() {
    zdot_set_theme_during_precmd
}

# ============================================================================
# OMZ Library Loading
# ============================================================================

_zdot_load_omz_lib() {
    local cache=$_ZDOT_PLUGINS_CACHE

    # Ensure the completions cache dir exists and is on fpath (idempotent)
    # (mirrors what use-omz.zsh does with $ZSH_CACHE_DIR/completions)
    mkdir -p "$ZSH_CACHE_DIR/completions"
    (( ${fpath[(Ie)"$ZSH_CACHE_DIR/completions"]} )) || fpath=( "$ZSH_CACHE_DIR/completions" $fpath )

    # ------------------------------------------------------------------
    # Lazy-loaded OMZ Libs (from use-omz)
    # These are left for user to decide to load or not:
    #   lib/completion.zsh
    #   lib/correction.zsh
    #   lib/diagnostics.zsh
    #   lib/directories.zsh
    #   lib/grep.zsh
    #   lib/history.zsh
    #   lib/key-bindings.zsh
    #   lib/misc.zsh
    #   lib/termsupport.zsh
    # ------------------------------------------------------------------

    zdot_omz_lazy_load_lib() {
        local lib=$1
        local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
        [[ -f "$cache/lib/$lib.zsh" ]] && source "$cache/lib/$lib.zsh"
    }

    # Disable OMZ async git prompt — it opens persistent fds via zle -F
    # that leak into process-substitution subshells (e.g. Ghostty's ssh
    # wrapper), causing hangs.  Must be set before git.zsh is sourced so
    # the zstyle -T check in git.zsh evaluates false.
    # See: https://github.com/ohmyzsh/ohmyzsh/issues/12328
    if ! zstyle -t ':omz:alpha:lib:git' async-prompt; then
        zstyle ':omz:alpha:lib:git' async-prompt no
    fi

    # lib/async_prompt.zsh (interactive only — opens persistent fds via
    # zle -F that leak into process-substitution subshells in wrappers
    # like Ghostty's ssh(), causing hangs)
    if zdot_interactive; then
        [[ "${+functions[_omz_register_handler]}" -gt 0 ]] ||
        function _omz_register_handler _omz_async_request _omz_async_callback {
            zdot_omz_lazy_load_lib async_prompt
            "$0" "$@"
        }
    fi

    # lib/bzr.zsh
    [[ "${+functions[bzr_prompt_info]}" -gt 0 ]] ||
    function bzr_prompt_info {
        zdot_omz_lazy_load_lib bzr
        "$0" "$@"
    }

    # lib/cli.zsh
    [[ "${+functions[omz]}" -gt 0 ]] ||
    function omz {
        zdot_omz_lazy_load_lib cli
        "$0" "$@"
    }

    # lib/clipboard.zsh
    [[ "${+functions[detect-clipboard]}" -gt 0 ]] ||
    function detect-clipboard clipcopy clippaste {
        unfunction detect-clipboard
        zdot_omz_lazy_load_lib clipboard
        detect-clipboard
        "$0" "$@"
    }

    # lib/compfix.zsh
    [[ "${+functions[handle_completion_insecurities]}" -gt 0 ]] ||
    function handle_completion_insecurities {
        zdot_omz_lazy_load_lib compfix
        "$0" "$@"
    }

    # lib/functions.zsh
    [[ "${+functions[open_command]}" -gt 0 ]] ||
    function env_default \
        open_command \
        omz_urldecode \
        omz_urlencode \
    {
        zdot_omz_lazy_load_lib functions
        "$0" "$@"
    }

    # lib/git.zsh
    [[ "${+functions[git_prompt_info]}" -gt 0 ]] ||
    function git_prompt_info \
        git_prompt_status \
        parse_git_dirty \
        git_remote_status \
        git_current_branch \
        git_commits_ahead \
        git_commits_behind \
        git_prompt_ahead \
        git_prompt_behind \
        git_prompt_remote \
        git_prompt_short_sha \
        git_prompt_long_sha \
        git_current_user_name \
        git_current_user_email \
        git_repo_name \
    {
        # Only load async_prompt in interactive shells — it opens
        # persistent fds via zle -F that leak into subshells
        if zdot_interactive; then
            [[ "${+functions[_omz_register_handler]}" -gt 0 ]] || zdot_omz_lazy_load_lib async_prompt
        fi
        zdot_omz_lazy_load_lib git
        "$0" "$@"
    }

    # lib/nvm.zsh
    [[ "${+functions[nvm_prompt_info]}" -gt 0 ]] ||
    function nvm_prompt_info {
        zdot_omz_lazy_load_lib nvm
        "$0" "$@"
    }

    # lib/prompt_info_functions.zsh
    [[ "${+functions[rvm_prompt_info]}" -gt 0 ]] ||
    function chruby_prompt_info \
        rbenv_prompt_info \
        hg_prompt_info \
        pyenv_prompt_info \
        svn_prompt_info \
        vi_mode_prompt_info \
        virtualenv_prompt_info \
        jenv_prompt_info \
        azure_prompt_info \
        tf_prompt_info \
        rvm_prompt_info \
        ruby_prompt_info \
    {
        zdot_omz_lazy_load_lib prompt_info_functions
        "$0" "$@"
    }

    _ZDOT_PLUGINS_LOADED[omz:lib]=1
}

zdot_load_omz_lib() {
    # Check if OMZ was disabled (re-check zstyle; local _zdot_omz_enabled is gone at call time)
    if ! zstyle -T ':zdot:plugins' omz; then
        return 0
    fi
    _zdot_load_omz_lib
}

# ============================================================================
# OMZ Plugin Cloning (delegated from core/plugins.zsh)
# ============================================================================

# OMZ plugins are cloned at file source time (see early setup above)
# This is a no-op - OMZ already cloned
zdot_bundle_omz_clone() {
    local spec=$1
    # Populate path cache so zdot_load_deferred_plugins avoids a subshell
    local relpath=${spec#omz:}
    _ZDOT_PLUGINS_PATH[$spec]="${_ZDOT_PLUGINS_CACHE}/ohmyzsh/ohmyzsh/${relpath}"
    return 0
}

# ============================================================================
# OMZ Plugin Loading (delegated from core/plugins.zsh)
# ============================================================================

# Path resolution for OMZ specs
zdot_bundle_omz_path() {
    local spec=$1
    local cache=$_ZDOT_PLUGINS_CACHE

    # omz:lib -> ohmyzsh/ohmyzsh/lib
    # omz:plugins/git -> ohmyzsh/ohmyzsh/plugins/git
    local relpath=${spec#omz:}  # "lib" or "plugins/git"
    REPLY="$cache/ohmyzsh/ohmyzsh/$relpath"
}

# Load OMZ plugin (handles both lib and plugins/*)
zdot_bundle_omz_load() {
    local spec=$1
    zdot_bundle_omz_path "$spec"
    local plugin_path=$REPLY

    # Check if it's omz:lib
    if [[ $spec == "omz:lib" ]]; then
        zdot_load_omz_lib
        return 0
    fi

    # Otherwise it's omz:plugins/<name>
    local plugin_name=${spec#omz:plugins/}
    local plugin_file="$plugin_path/$plugin_name.plugin.zsh"

    [[ -d "$plugin_path" ]] || return 1
    [[ -f "$plugin_file" ]] || return 1

    # Mark as loaded
    _ZDOT_PLUGINS_LOADED[$spec]=1

    fpath+=( "$plugin_path" )
    source "$plugin_file"

    # Optionally compile to .zwc for faster loading (opt-out: enabled by default)
    if zstyle -T ':zdot:plugins' compile; then
        zdot_cache_compile_file "$plugin_file" 2>/dev/null || true
    fi

    return 0
}

zdot_load_omz_plugins() {
    local plugin
    for plugin in "$@"; do
        zdot_bundle_omz_load "$plugin" 2>/dev/null || true
    done
}

# ============================================================================
# Plugin Bundle API
# ============================================================================

# Match function: returns 0 if this handler owns the spec
zdot_bundle_omz_match() {
    [[ $1 == omz:* ]]
}

# ============================================================================
# Enabled-gated side effects
# Everything below this point has observable side effects (variable setup,
# hook/bundle registration, lazy-load stubs) and must only run when OMZ is
# enabled.  When disabled, optionally remove the cloned repo from disk.
# ============================================================================

if [[ "$_zdot_omz_enabled" == yes ]]; then

    # ------------------------------------------------------------------
    # Bundle init function: called by zdot_init during bundle init pass
    # ------------------------------------------------------------------

    # Real OMZ setup work — registered as a hook so that all hooks in the
    # omz-configure group (user-space zstyle calls, etc.) are guaranteed to
    # have run before this fires.
    _zdot_bundle_omz_setup() {
        # Step 1: OMZ self-update check
        if zdot_interactive && zdot_has_tty; then
            zdot_omz_check_for_upgrade
        fi

        # Step 2: Set OMZ environment variables and state
        # Bugfix: OMZ has a regression where async-prompt can cause issues.
        if ! zstyle -t ':omz:alpha:lib:git' async-prompt; then
            zstyle ':omz:alpha:lib:git' async-prompt no
        fi

        # Set ZSH to the OMZ installation directory (required by OMZ plugins/themes)
        [[ -n "$ZSH" ]] || ZSH="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"

        # Set ZSH_CUSTOM to the path where custom config files and plugins exist
        [[ -n "$ZSH_CUSTOM" ]] || ZSH_CUSTOM="$ZSH/custom"

        # Set ZSH_CACHE_DIR for cache files (use zdot-specific prefix)
        [[ -n "$ZSH_CACHE_DIR" ]] || ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ohmyzsh"

        typeset -g _ZDOT_THEME_LOADED=0
        typeset -g ZSH_THEME
    }

    # Bundle init function: called directly by _zdot_init_bundles.
    # Does NOT do OMZ setup inline — instead registers _zdot_bundle_omz_setup
    # as a hook so that all omz-configure group hooks (user-space zstyle calls)
    # run first via the normal hook resolution pass.
    #
    # All three hooks are registered here (before plan build) so that their
    # dep edges are visible to the topological sort:
    #   omz-configure group → _zdot_bundle_omz_setup
    #                       → _zdot_omz_load_lib
    #                       → omz-plugins group members
    #                       → zdot_omz_theme_init
    zdot_bundle_omz_init() {
        zdot_register_hook _zdot_bundle_omz_setup interactive noninteractive \
            --provides omz-bundle-initialized \
            --requires-group omz-configure

        # Load omz:lib; --provides-group omz-plugins means any hook tagged
        # --group omz-plugins gets --requires omz-lib-loaded injected.
        zdot_register_hook _zdot_omz_load_lib interactive noninteractive \
            --requires omz-bundle-initialized \
            --provides omz-lib-loaded \
            --provides-group omz-plugins

        # Theme init runs after all omz-plugins group members have loaded.
        zdot_register_hook zdot_omz_theme_init interactive noninteractive \
            --requires omz-lib-loaded \
            --provides omz-theme-ready
    }

    # ------------------------------------------------------------------
    # Plugin Bundle API registration
    # ------------------------------------------------------------------

    # Register this bundle handler with the registry
    zdot_register_bundle omz \
        --init-fn zdot_bundle_omz_init \
        --provides omz-bundle-initialized
    zdot_use_bundle ohmyzsh/ohmyzsh

    # Bundle-specific compdump stamp: OMZ git HEAD revision.
    # Overrides the default stub in core/compinit.zsh.
    _zdot_compdump_bundle_stamp() {
        local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
        cd "$cache" 2>/dev/null && git rev-parse HEAD 2>/dev/null
    }

    # ------------------------------------------------------------------
    # Hook Registration
    # ------------------------------------------------------------------

    # Load omz:lib so downstream hooks (theme, prompt funcs) don't need to
    # depend on the user-space omz-plugins-loaded phase.
    _zdot_omz_load_lib() {
        zdot_load_plugin omz:lib
    }

    # OMZ theme hook: loads theme during precmd if ZSH_THEME is set
    # Depends on omz-lib-loaded (omz:lib sourced), provides omz-theme-ready
    zdot_omz_theme_init() {
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd zdot_omz_theme_hook
    }

fi
