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
#   - op_get_vault_config: Reads vault names from zstyle with defaults
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
#
# Configuration Group:
#   - Group: secrets-configure
#     Hooks in this group run before _op_init. Register user hooks with:
#       zdot_register_hook my_op_configure interactive noninteractive \
#           --group secrets-configure
#     Then set zstyles to override vault names used by op_refresh:
#       zstyle ':zdot:secrets:op' service-acct-vault 'MyServiceAcctVault'
#       zstyle ':zdot:secrets:op' api-vault          'MyAPIVault'
#       zstyle ':zdot:secrets:op' ssh-vault          'MySSHVault'
#       zstyle ':zdot:secrets:op' service-acct-grants \
#           'MyAPIVault:read_items,write_items' \
#           'MySSHVault:read_items,write_items'
#
# SSH Agent Configuration:
#   zstyle ':zdot:secrets' ssh-platforms  - $OSTYPE glob patterns; agent setup
#                                           only runs when one matches.
#                                           Default: ('darwin*')
#   zstyle ':zdot:secrets' ssh-func       - optional function name; called with
#                                           no args, setup only proceeds if it
#                                           returns 0. Default: unset.

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
#
# Platform guard:
#   zstyle ':zdot:secrets' ssh-platforms  - list of platform names or $OSTYPE
#                                           globs; setup only runs when one
#                                           matches. Accepts friendly names:
#                                           'mac', 'linux', 'debian', or raw
#                                           globs like 'darwin*'. Default: (mac)
#   zstyle ':zdot:secrets' ssh-func       - name of a function to call; when set
#                                           it replaces the built-in SSH_CONNECTION
#                                           guard entirely. Not set by default.
_setup_ssh_auth_sock() {
    command -v op &> /dev/null || return 0

    # Platform check via is-platform (supports 'mac', 'linux', 'debian', globs)
    local -a ssh_platforms
    zstyle -a ':zdot:secrets' ssh-platforms ssh_platforms \
        || ssh_platforms=(mac)
    is-platform "${ssh_platforms[@]}" || return 0

    # Default condition: skip when in an SSH connection.
    # Overridable via ssh-func — if set it replaces this check entirely.
    local ssh_func
    zstyle -s ':zdot:secrets' ssh-func ssh_func
    if [[ -n "$ssh_func" ]]; then
        typeset -f "$ssh_func" > /dev/null || {
            zdot_warn "secrets: ssh-func '${ssh_func}' is not defined, skipping SSH agent setup"
            return 0
        }
        "$ssh_func" || return 0
    else
        # Built-in default: do not set up agent when connected over SSH
        [[ -n "${SSH_CONNECTION}" ]] && return 0
    fi

    # Perform the setup
    if [[ ! -d ~/.1password || ! -L ~/.1password/agent.sock ]]; then
        mkdir -p ~/.1password \
            && ln -s ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock \
                      ~/.1password/agent.sock
    fi
    export SSH_AUTH_SOCK=~/.1password/agent.sock
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
    op_config=("${(@f)$(op_get_config_args)}")  # shuck: ignore=C001

    # Check if config exists - set flag accordingly
    if [[ ! -f "${op_config_dir}/config" ]]; then
        _ZDOT_OP_ACTIVE=0
    fi

    # Refresh service account if source is newer or dest is missing
    if zdot_is_newer_or_missing "${secrets_src_dir}/op-secrets.zsh" "${secrets_cache}/${USER}.op-secrets.zsh"; then
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
        if zdot_is_newer_or_missing "${secrets_src_dir}/secrets.zsh" "${secrets_cache}/${USER}.secrets.zsh"; then
            refresh_shell_secrets
        else
            zdot_verbose "secrets: cache is up to date, skipping refresh"
        fi

        # Source shell secrets if available
        if [[ -f "${secrets_cache}/${USER}.secrets.zsh" ]]; then
            source "${secrets_cache}/${USER}.secrets.zsh"
        fi
    else
        # Warn if secrets template is stale but OP is not active to refresh it
        if zdot_is_newer_or_missing "${secrets_src_dir}/secrets.zsh" "${secrets_cache}/${USER}.secrets.zsh"; then
            zdot_warn "secrets: template is newer than cache but OP is not active — run refresh_shell_secrets manually once OP is available"
        fi
    fi

    # Set up SSH auth socket (works in both interactive and noninteractive)
    _setup_ssh_auth_sock
}

# Register hook - requires xdg-configured and the secrets-configure group,
# provides secrets-loaded.  Any user hook registered with --group secrets-configure
# is guaranteed to run before this.
# Runs in both interactive and noninteractive modes;
# interactive prompts only happen in interactive shells due to function guards.
zdot_register_hook _op_init interactive noninteractive \
    --requires xdg-configured \
    --requires-tool op \
    --requires-group secrets-configure \
    --provides secrets-loaded
