#!/usr/bin/env zsh
# mcp: mcp setup
#

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

# Module initialization - set up MCP secrets
_mcp_init() {
    command -v op &> /dev/null || return 0

    # Get secrets directories
    local secrets_src_dir secrets_cache secrets_mcp_dir
    _mcp_get_secrets_mcp_dirs
    [[ ! -d "${secrets_mcp_dir}" ]] && mkdir -p "${secrets_mcp_dir}"

    # Refresh MCP servers config if needed
    # This only runs if secrets-loaded phase was provided (optional dependency)
    if zdot_is_newer_or_missing "${secrets_src_dir}/mcpservers.json" "${secrets_cache}/${USER}.mcpservers.json"; then
        refresh_mcpservers_secret
    fi
}

# Register hook - optionally requires secrets-loaded, provides mcp-configured
# Runs in both interactive and noninteractive modes
# Will skip gracefully if secrets are not available (optional dependency)
zdot_hook_register _mcp_init interactive noninteractive --requires xdg-configured secrets-loaded --provides mcp-configured --optional
