#!/usr/bin/env zsh
# op: 1Password secrets management
#
# This module manages 1Password integration for secrets and SSH authentication.
# It runs in both interactive and noninteractive contexts, but interactive prompts
# are guarded to only run in interactive shells.
#
# Inline Functions:
#   - _op_get_secrets_dirs: Returns secrets_src_dir and secrets_cache
#   - _setup_ssh_auth_sock: Sets up SSH_AUTH_SOCK for 1Password agent
#   - _op_init: Module initialization, orchestrates secret loading
#
# Autoloaded Functions (in functions/):
#   - op_get_config_dir: Returns op config directory path via stdout
#   - op_get_config_args: Returns op config arguments via stdout (one per line)
#   - op_auth: Handles authentication setup (interactive only)
#   - op_refresh: Refreshes service account, calls op_auth if needed
#   - refresh_shell_secrets: Refreshes shell environment secrets
#   - refresh_mcpservers_secret: Refreshes MCP servers configuration
#
# Global State:
#   - _ZDOT_OP_ACTIVE: Set to 1 when service account is configured and working
#
# Behavior:
#   - Noninteractive: Only loads existing cached secrets, no prompts
#   - Interactive: May prompt for setup/authentication if not configured

typeset -g _ZDOT_OP_ACTIVE=0

# Autoload module functions
zdot_module_autoload_funcs

# Get secrets directories
# Returns via caller-declared local variables:
#   secrets_src_dir - source directory for secret templates
#   secrets_cache - cache directory for processed secrets
_op_get_secrets_dirs() {
    secrets_src_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/secrets"
    secrets_cache="${XDG_CACHE_HOME:-$HOME/.cache}/secrets/"
}

# Set up SSH_AUTH_SOCK to use 1Password SSH agent
_setup_ssh_auth_sock() {
    command -v op &> /dev/null || return 0

    # Only set up on macOS and when not in SSH connection
    if [[ -z "${SSH_CONNECTION}" && is-macos ]]; then
        if [[ ! -d ~/.1password || ! -L ~/.1password/agent.sock ]]; then
            mkdir -p ~/.1password && ln -s ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock ~/.1password/agent.sock
        fi
        export SSH_AUTH_SOCK=~/.1password/agent.sock
    fi
}

# Module initialization - set up 1Password secrets
_op_init() {
    command -v op &> /dev/null || return 0

    # Get secrets directories
    local secrets_src_dir secrets_cache
    _op_get_secrets_dirs
    [[ ! -d "${secrets_cache}" ]] && mkdir -p "${secrets_cache}"

    # Get op config
    local -a op_config
    local op_config_dir
    op_config_dir=$(op_get_config_dir)
    op_config=("${(@f)$(op_get_config_args)}")

    # Check if config exists - set flag accordingly
    if [[ ! -f "${op_config_dir}/config" ]]; then
        _ZDOT_OP_ACTIVE=0
    fi

    # Refresh service account if source is newer or dest is missing
    if src-newer-or-dest-missing "${secrets_src_dir}/op-secrets.zsh" "${secrets_cache}/${USER}.op-secrets.zsh"; then
        op_refresh
    fi

    # Source the service account token if available
    if [[ -f "${secrets_cache}/${USER}.op-secrets.zsh" ]]; then
        source "${secrets_cache}/${USER}.op-secrets.zsh"
        # If we have a token, mark as active
        [[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ]] && _ZDOT_OP_ACTIVE=1
    fi

    # Only proceed with shell secrets if OP is active
    if [[ $_ZDOT_OP_ACTIVE -eq 1 ]]; then
        # Refresh shell secrets if needed
        if src-newer-or-dest-missing "${secrets_src_dir}/secrets.zsh" "${secrets_cache}/${USER}.secrets.zsh"; then
            refresh_shell_secrets
        fi
        
        # Source shell secrets if available
        if [[ -f "${secrets_cache}/${USER}.secrets.zsh" ]]; then
            source "${secrets_cache}/${USER}.secrets.zsh"
        fi
    fi

    # Set up SSH auth socket (works in both interactive and noninteractive)
    _setup_ssh_auth_sock
}

# Register hook - runs in both interactive and noninteractive modes
# Interactive prompts only happen in interactive shells due to function guards
zdot_hook_register secrets _op_init interactive noninteractive
