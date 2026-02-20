#!/bin/zsh

# Global quiet mode setting - defaults to not quiet
# These can be overridden via zstyle before zdot.zsh is sourced:
#   zstyle ':zdot:logging' quiet   true
#   zstyle ':zdot:logging' verbose true
zdot_quiet_mode=false
zdot_verbose_mode=false
zstyle -t ':zdot:logging' quiet   && zdot_quiet_mode=true
zstyle -t ':zdot:logging' verbose && zdot_verbose_mode=true

function zdot_cleanup_logging(){
    # Unset variables
    unset zdot_quiet_mode 2>/dev/null
    unset zdot_verbose_mode 2>/dev/null

    # Unset all functions defined in this file
    unset -f zdot_cleanup_logging 2>/dev/null
    unset -f zdot_info 2>/dev/null
    unset -f zdot_info_nonnl 2>/dev/null
    unset -f zdot_success 2>/dev/null
    unset -f zdot_report 2>/dev/null
    unset -f zdot_action 2>/dev/null
    unset -f zdot_error 2>/dev/null
    unset -f zdot_warn 2>/dev/null
}

# Helper output functions that respect zdot_quiet_mode
function zdot_verbose(){
    [[ "$zdot_verbose_mode" = true ]] && print -P "$@"
    return 0
}

function zdot_info(){
    [[ "$zdot_quiet_mode" = true ]] || print -P "$@"
}

function zdot_info_nonl(){
    [[ "$zdot_quiet_mode" = true ]] || print -n -P "$@"
}

function zdot_success(){
    [[ "$zdot_quiet_mode" = true ]] || print -P "%F{green}$@%f"
}

function zdot_report(){
    [[ "$zdot_quiet_mode" = true ]] || print -P "%F{cyan}$@%f"
}

function zdot_action(){
    [[ "$zdot_quiet_mode" = true ]] || print -P "%F{blue}$@%f"
}

function zdot_error(){
    [[ "$zdot_quiet_mode" = true ]] || print -P "%F{red}$@%f"
}

function zdot_warn(){
    [[ "$zdot_quiet_mode" = true ]] || print -P "%F{yellow}$@%f"
}
