#!/usr/bin/env zsh
# mcp: mcp setsup
#

typeset -g _ZDOT_OP_ACTIVE=0

# Autoload module functions
zdot_module_autoload_funcs

# Get secrets directories
# Returns via caller-declared local variables:
#   secrets_src_dir - source directory for secret templates
#   secrets_cache - cache directory for processed secrets
_mcp_get_secrets_mcp_dirs() {
    secrets_src_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/secrets"
    secrets_cache="${XDG_CACHE_HOME:-$HOME/.cache}/secrets"
    secrets_mcp_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/secrets/${USER}.mcp"
}

# Module initialization - set up 1Password secrets
_mcp_init() {
    command -v op &> /dev/null || return 0

    # Get secrets directories
    local secrets_src_dir secrets_cache secrets_mcp_dir
    _mcp_get_secrets_mcp_dirs
    [[ ! -d "${secrets_mcp_dir}" ]] && mkdir -p "${secrets_mcp_dir}"

    # Only proceed with shell secrets if OP is active
    if [[ $_ZDOT_OP_ACTIVE -eq 1 ]]; then
        # Refresh shell secrets if needed
        # Refresh MCP servers config if needed
        if src-newer-or-dest-missing "${secrets_src_dir}/mcpservers.json" "${secrets_cache}/${USER}.mcpservers.json"; then
            refresh_mcpservers_secret
        fi
    fi
}

# Register hook - runs in both interactive and noninteractive modes
# Interactive prompts only happen in interactive shells due to function guards
zdot_hook_register after-secrets _mcp_init interactive noninteractive
