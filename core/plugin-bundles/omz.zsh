#!/usr/bin/env zsh
# core/plugin-bundles/omz.zsh: OMZ plugin bundle handler
# Provides:
#   - Compdef queue (queue compdef calls before compinit)
#   - Compinit deferral (defer compinit for faster startup)
#   - has-zcompdump-expired (check if compdump needs refresh)
#   - ensure-compinit-during-precmd (re-run compinit on precmd if needed)
#   - SHORT_HOST detection
#   - ZSH_CUSTOM / ZSH_CACHE_DIR setup
#   - OMZ self-update check
#   - Background zrecompile
#   - OMZ lib loading
#   - OMZ plugin loading
#   - Lazy-loaded OMZ lib stubs

# ============================================================================
# Early Setup: Clone OMZ if enabled
# ============================================================================

local _zdot_omz_enabled
zstyle -b ':zdot:plugins' omz _zdot_omz_enabled || _zdot_omz_enabled=true

if [[ "$_zdot_omz_enabled" == true ]]; then
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

# Bugfix: OMZ has a regression where async-prompt can cause issues
# If async isn't explicitly set, make it 'no' for now
if ! zstyle -t ':omz:alpha:lib:git' async-prompt; then
    zstyle ':omz:alpha:lib:git' async-prompt no
fi

# ============================================================================
# OMZ Core Variables (from use-omz)
# ============================================================================

# Set ZSH_CUSTOM to the path where custom config files and plugins exist
[[ -n "$ZSH_CUSTOM" ]] || ZSH_CUSTOM="${ZSH_CUSTOM_DIR:-${ZDOTDIR:-$HOME}/.oh-my-zsh/custom}"

# Set ZSH_CACHE_DIR for cache files (use zdot-specific prefix)
[[ -n "$ZSH_CACHE_DIR" ]] || ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zdot/omz"

# Create cache and completions dir and add to fpath
[[ -d "$ZSH_CACHE_DIR/completions" ]] || mkdir -p "$ZSH_CACHE_DIR/completions"
(( ${fpath[(Ie)"$ZSH_CACHE_DIR/completions"]} )) || fpath=("$ZSH_CACHE_DIR/completions" $fpath)

# ============================================================================
# OMZ Self-Update Check
# ============================================================================

zdot_omz_check_for_upgrade() {
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    [[ -f "$cache/tools/check_for_upgrade.sh" ]] && source "$cache/tools/check_for_upgrade.sh"
}

# ============================================================================
# SHORT_HOST Detection
# ============================================================================

typeset -g SHORT_HOST

zdot_omz_init_short_host() {
    [[ -n "$SHORT_HOST" ]] && return 0
    
    if [[ "$OSTYPE" = darwin* ]]; then
        SHORT_HOST=$(scutil --get LocalHostName 2>/dev/null) || SHORT_HOST="${HOST/.*/}"
    else
        SHORT_HOST="${HOST/.*/}"
    fi
}

# ============================================================================
# Compdef Queue
# ============================================================================

# Queue for compdef calls that happen before compinit
typeset -ga _ZDOT_COMPDEF_QUEUE
typeset -g  _ZDOT_COMPDEF_QUEUE_INITIALIZED=0

_zdot_compdef_queue_init() {
    [[ $_ZDOT_COMPDEF_QUEUE_INITIALIZED -eq 1 ]] && return 0
    
    _ZDOT_COMPDEF_QUEUE=()
    _ZDOT_COMPDEF_QUEUE_INITIALIZED=1
}

_compdef_queue() {
    _zdot_compdef_queue_init
    _ZDOT_COMPDEF_QUEUE+=("$*")
}

zdot_compdef() {
    if [[ -n "$_ZDOT_COMPINIT_DONE" ]]; then
        compdef "$@"
    else
        _compdef_queue "$@"
    fi
}

zdot_compdef_queue_process() {
    if [[ ${#_ZDOT_COMPDEF_QUEUE} -eq 0 ]]; then
        return 0
    fi
    
    local cmd
    for cmd in "$_ZDOT_COMPDEF_QUEUE[@]"; do
        eval "compdef $cmd"
    done
    
    _ZDOT_COMPDEF_QUEUE=()
}

# ============================================================================
# Compdump Expiry Check (has-zcompdump-expired)
# ============================================================================

typeset -g _ZDOT_COMPFILE

zdot_init_compfile() {
    [[ -n "$_ZDOT_COMPFILE" ]] && return 0
    
    zdot_omz_init_short_host
    
    local host_suffix=""
    [[ -n "$SHORT_HOST" ]] && host_suffix="-${SHORT_HOST}"
    _ZDOT_COMPFILE="${ZDOTDIR:-${HOME}}/.zcompdump${host_suffix}-${ZSH_VERSION}"
}

zdot_has_zcompdump_expired() {
    zdot_init_compfile
    
    local compfile="$_ZDOT_COMPFILE"
    local max_age_hours=${1:-24}
    
    if [[ ! -f "$compfile" ]]; then
        return 0
    fi
    
    local age_seconds=$(($(date +%s) - $(stat -f %m "$compfile" 2>/dev/null || stat -c %Y "$compfile" 2>/dev/null)))
    local age_hours=$((age_seconds / 3600))
    
    [[ $age_hours -ge $max_age_hours ]]
}

zdot_compdump_needs_refresh() {
    zdot_init_compfile
    
    local compfile="$_ZDOT_COMPFILE"
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    
    if [[ ! -f "$compfile" ]]; then
        return 0
    fi
    
    local old_rev old_fpath
    old_rev=$(grep -Fx '#omz revision:' "$compfile" 2>/dev/null | cut -d: -f3)
    old_fpath=$(grep -Fx '#omz fpath:' "$compfile" 2>/dev/null | cut -d: -f2-)
    
    if [[ -z "$old_rev" || -z "$old_fpath" ]]; then
        return 0
    fi
    
    local current_rev
    current_rev=$(cd "$cache" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
    
    if [[ "$current_rev" != "$old_rev" ]]; then
        return 0
    fi
    
    local current_fpath="${fpath[*]}"
    if [[ "$old_fpath" != "$current_fpath" ]]; then
        return 0
    fi
    
    return 1
}

# ============================================================================
# Compinit Deferral
# ============================================================================

typeset -g _ZDOT_COMPINIT_DEFERRED=0

zdot_compinit_defer() {
    # Skip compinit in non-interactive shells - completions not needed
    [[ -o interactive ]] || return 0
    
    [[ $_ZDOT_COMPINIT_DEFERRED -eq 1 ]] && return 0
    
    _zdot_compdef_queue_init
    zdot_init_compfile
    
    autoload -Uz compinit
    
    local compfile="$_ZDOT_COMPFILE"
    local do_compinit=1
    
    if [[ -f "$compfile" ]] && ! zdot_compdump_needs_refresh; then
        do_compinit=0
    fi
    
    if [[ $do_compinit -eq 1 ]]; then
        if [[ "$ZSH_DISABLE_COMPFIX" != true ]]; then
            autoload -Uz compaudit
            compinit -i -d "$compfile"
        else
            compinit -u -d "$compfile"
        fi
        
        local omz_rev cache
        cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
        omz_rev=$(cd "$cache" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
        
        if [[ -n "$omz_rev" ]]; then
            {
                echo
                echo "#omz revision:$omz_rev"
                echo "#omz fpath:${fpath[*]}"
            } >> "$compfile"
        fi
        
        {
            if [[ -s "$compfile" && (! -s "${compfile}.zwc" || "$compfile" -nt "${compfile}.zwc") ]]; then
                if command mkdir "${compfile}.lock" 2>/dev/null; then
                    autoload -U zrecompile
                    zrecompile -q -p "$compfile"
                    command rm -rf "${compfile}.zwc.old" "${compfile}.lock" 2>/dev/null
                fi
            fi
        } &!
    fi
    
    _ZDOT_COMPINIT_DONE=1
    _ZDOT_COMPINIT_DEFERRED=1
    zdot_compdef_queue_process
    
    return 0
}

zdot_compinit_reexec() {
    compinit -i
    _ZDOT_COMPINIT_DONE=1
    zdot_compdef_queue_process
}

# ============================================================================
# Ensure Compinit During Precmd
# ============================================================================

typeset -g _ZDOT_COMPINIT_CHECKED_DURING_PRECMD=0

zdot_ensure_compinit_during_precmd() {
    [[ $_ZDOT_COMPINIT_CHECKED_DURING_PRECMD -eq 1 ]] && return 0
    [[ -n "$_ZDOT_COMPINIT_DONE" ]] && return 0
    
    _ZDOT_COMPINIT_CHECKED_DURING_PRECMD=1
    
    if zdot_compdump_needs_refresh; then
        zdot_compinit_reexec
    fi
}

zdot_enable_compinit_precmd() {
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd zdot_ensure_compinit_during_precmd
}

# ============================================================================
# Theme During Precmd (like antidote's set-omz-theme-during-precmd)
# Only loads theme if ZSH_THEME is set
# ============================================================================

typeset -g _ZDOT_OMZ_THEME_PRECMD_SET=0
typeset -g _ZDOT_THEME_LOADED=0
typeset -g ZSH_THEME

zdot_load_omz_theme() {
    local theme_name="${1:-$ZSH_THEME}"
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    local custom="${ZDOTDIR:-$HOME}/.oh-my-zsh/custom"
    
    local theme_file
    
    if [[ -f "$custom/themes/$theme_name.zsh-theme" ]]; then
        theme_file="$custom/themes/$theme_name.zsh-theme"
    elif [[ -f "$custom/$theme_name.zsh-theme" ]]; then
        theme_file="$custom/$theme_name.zsh-theme"
    elif [[ -f "$cache/themes/$theme_name.zsh-theme" ]]; then
        theme_file="$cache/themes/$theme_name.zsh-theme"
    fi
    
    if [[ -n "$theme_file" ]]; then
        source "$theme_file"
        _ZDOT_THEME_LOADED=1
    fi
}

zdot_set_theme_during_precmd() {
    [[ $_ZDOT_OMZ_THEME_PRECMD_SET -eq 1 ]] && return 0
    [[ -n "$ZSH_THEME" ]] || return 0
    
    _ZDOT_OMZ_THEME_PRECMD_SET=1
    
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    local custom="${ZDOTDIR:-$HOME}/.oh-my-zsh/custom"
    
    local -A aliases_pre
    local key
    for key in 'ls'; do
        [[ -n "${aliases[$key]:-}" ]] && aliases_pre[$key]=$aliases[$key]
    done
    
    [[ -n "${FX:-}" ]] && [[ -n "${FG:-}" ]] && [[ -n "${BG:-}" ]] || source "$cache/lib/spectrum.zsh" 2>/dev/null
    [[ -n "${ZSH_THEME_GIT_PROMPT_PREFIX:-}" ]] || source "$cache/lib/theme-and-appearance.zsh" 2>/dev/null
    source "$cache/lib/vcs_info.zsh" 2>/dev/null
    
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
    local omz_lib="$cache/ohmyzsh/ohmyzsh/lib"
    
    fpath+=( "$omz_lib" )
    
    local lib_file
    for lib_file in functions compfix completion key-bindings termsupport; do
        if [[ -f "$omz_lib/$lib_file.zsh" ]]; then
            source "$omz_lib/$lib_file.zsh"
        fi
    done
    
    # Mark as loaded
    _ZDOT_PLUGINS_LOADED[omz:lib]=1
}

zdot_load_omz_lib() {
    # Check if OMZ was disabled
    if [[ "$_zdot_omz_enabled" != true ]]; then
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
    print "$cache/ohmyzsh/ohmyzsh/$relpath"
}

# Load OMZ plugin (handles both lib and plugins/*)
zdot_bundle_omz_load() {
    local spec=$1
    local plugin_path=$(zdot_bundle_omz_path "$spec")
    
    # Check if it's omz:lib
    if [[ $spec == "omz:lib" ]]; then
        if typeset -f zdot_load_omz_lib > /dev/null; then
            zdot_load_omz_lib
        else
            _zdot_load_omz_lib
        fi
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
    
    # Optionally compile to .zwc for faster loading
    local compile_plugins
    zstyle -b ':zdot:plugins' compile compile_plugins || compile_plugins=false
    if [[ "$compile_plugins" == true ]]; then
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

zdot_use_omz() {
    zdot_use omz:lib
}

# Register this bundle handler with the registry
zdot_bundle_register omz

# ============================================================================
# Hook Registration for zdot
# These are called by the zdot hook system
# ============================================================================

# OMZ theme hook: loads theme during precmd if ZSH_THEME is set
# Depends on omz-lib-loaded (compinit done), provides omz-theme-ready
zdot_omz_theme_init() {
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd zdot_omz_theme_hook
}

zdot_hook_register zdot_omz_theme_init interactive \
    --requires omz-lib-loaded \
    --provides omz-theme-ready

# ============================================================================
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
# ============================================================================

zdot_omz_lazy_load_lib() {
    local lib=$1
    local cache="$_ZDOT_PLUGINS_CACHE/ohmyzsh/ohmyzsh"
    [[ -f "$cache/lib/$lib.zsh" ]] && source "$cache/lib/$lib.zsh"
}

# lib/async_prompt.zsh
[[ "${+functions[_omz_register_handler]}" -gt 0 ]] ||
function _omz_register_handler _omz_async_request _omz_async_callback {
    zdot_omz_lazy_load_lib async_prompt.zsh
    "$0" "$@"
}

# lib/bzr.zsh
[[ "${+functions[bzr_prompt_info]}" -gt 0 ]] ||
function bzr_prompt_info {
    zdot_omz_lazy_load_lib bzr.zsh
    "$0" "$@"
}

# lib/cli.zsh
[[ "${+functions[omz]}" -gt 0 ]] ||
function omz {
    zdot_omz_lazy_load_lib cli.zsh
    "$0" "$@"
}

# lib/clipboard.zsh
[[ "${+functions[detect-clipboard]}" -gt 0 ]] ||
function detect-clipboard clipcopy clippaste {
    unfunction detect-clipboard
    zdot_omz_lazy_load_lib clipboard.zsh
    detect-clipboard
    "$0" "$@"
}

# lib/compfix.zsh
[[ "${+functions[handle_completion_insecurities]}" -gt 0 ]] ||
function handle_completion_insecurities {
    zdot_omz_lazy_load_lib compfix.zsh
    "$0" "$@"
}

# lib/functions.zsh
[[ "${+functions[open_command]}" -gt 0 ]] ||
function env_default \
    open_command \
    omz_urldecode \
    omz_urlencode \
{
    zdot_omz_lazy_load_lib functions.zsh
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
    [[ "${+functions[_omz_register_handler]}" -gt 0 ]] || zdot_omz_lazy_load_lib async_prompt.zsh
    zdot_omz_lazy_load_lib git.zsh
    "$0" "$@"
}

# lib/nvm.zsh
[[ "${+functions[nvm_prompt_info]}" -gt 0 ]] ||
function nvm_prompt_info {
    zdot_omz_lazy_load_lib nvm.zsh
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
    zdot_omz_lazy_load_lib prompt_info_functions.zsh
    "$0" "$@"
}

# ============================================================================
# Prompt Functions (interactive only - lazy loaded)
# ============================================================================

_zdot_omz_setup_prompt_funcs() {
    # lib/nvm.zsh
    [[ "${+functions[nvm_prompt_info]}" -gt 0 ]] ||
    function nvm_prompt_info {
        zdot_omz_lazy_load_lib nvm.zsh
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
        zdot_omz_lazy_load_lib prompt_info_functions.zsh
        "$0" "$@"
    }
}

zdot_hook_register _zdot_omz_setup_prompt_funcs interactive \
    --requires omz-lib-loaded \
    --provides omz-prompt-funcs-ready
