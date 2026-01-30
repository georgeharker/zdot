#!/usr/bin/env zsh
# op: 1Password secrets management

# Module initialization - set up 1Password secrets
_op_init() {
    command -v op &> /dev/null || return 0

    SECRETS_SRC_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/secrets"
    SECRETS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/secrets/"
    [[ ! -d "${SECRETS_CACHE}" ]] && mkdir -p ${SECRETS_CACHE}

    op_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/op"
    local op_config=()
    if [[ ${SUDO_USER} != "" ]]; then
        op_config=("--config" "${REAL_HOME}/.config/op")
    fi

    function refresh_op_client_secrets() {
        typeset +x OP_SERVICE_ACCOUNT_TOKEN
        rm -f "${SECRETS_CACHE}/${USER}.op-secrets.zsh"

        if [[ -f ${op_config_dir}/no_op ]]; then
            return
        fi

        if [[ ! -f ${op_config_dir}/config && ! -f ${op_config_dir}/no_op ]]; then
            printf "Set up onepassword ? [Y/n/c] "
            read -r -k 1 option
            [[ "$option" = $'\n' ]] || echo
            case "$option" in
                [yY$'\n']) ;;
                [nN]) touch ${op_config_dir}/no_op && return ;;
                *) echo "You will be asked at next login" ;;
            esac
        fi

        echo "Using 1Password to refresh service account"
        if ! op whoami ${op_config} &> /dev/null; then
            echo "Sign into 1Password"
            eval $(op ${op_config} signin)
        fi
        local new_svc_acct=0
        printf "Create new service-account? [Y/n/c] "
        read -r -k 1 option
        [[ "$option" = $'\n' ]] || echo
        case "$option" in
            [yY$'\n']) new_svc_acct=1 ;;
            [nN]) new_svc_acct=0 ;;
            *) echo "You will be asked at next login" ;;
        esac

        local host_service_account="$(hostname)-service-account"

        if [ $new_svc_acct -eq 1 ]; then
            local svc_acct_output=$(op service-account create "$host_service_account" --can-create-vaults \
                                        --vault API:read_items \
                                        --vault SSHKeys:read_items,write_items | grep "export OP_SERVICE_ACCOUNT_TOKEN=")
            if [[ $? -eq 0 ]]; then
                local acct_key=$(eval "$svc_acct_output"; echo $OP_SERVICE_ACCOUNT_TOKEN)
                op item create --vault ServiceAcct \
                                --category "API Credential" \
                                --title "$host_service_account" - \
                                "credential=$acct_key" \
                                "validFrom[string]=" \
                                "expires[string]=" \
                                "host=$(hostname)" > /dev/null
                echo "export OP_SERVICE_ACCOUNT_TOKEN=op://ServiceAcct/${host_service_account}/credential" > "${SECRETS_SRC_DIR}/op-secrets.zsh"
                if op ${op_config} inject --force --in-file "${SECRETS_SRC_DIR}/op-secrets.zsh" --out-file "${SECRETS_CACHE}/${USER}.op-secrets.zsh" > /dev/null; then
                    op signout
                else
                    echo "Failed to refresh 1Password service account"
                fi
            else
                echo "Failed to refresh 1Password service account"
            fi
        else
            if [[ ! -f "${SECRETS_SRC_DIR}/op-secrets.zsh" ]]; then
                printf "Accounts:"
                op item list --vault ServiceAcct
                printf "Choose account name: "
                read -r name
                echo "export OP_SERVICE_ACCOUNT_TOKEN=op://ServiceAcct/${host_service_account}/credential" > "${SECRETS_SRC_DIR}/op-secrets.zsh"
            fi
            if op ${op_config} inject --force --in-file "${SECRETS_SRC_DIR}/op-secrets.zsh" --out-file "${SECRETS_CACHE}/${USER}.op-secrets.zsh" > /dev/null; then
                op signout
            else
                echo "Failed to refresh 1Password service account"
            fi
        fi
    }

    # First set up service key
    if src-newer-or-dest-missing "${SECRETS_SRC_DIR}/op-secrets.zsh" "${SECRETS_CACHE}/${USER}.op-secrets.zsh"; then
        refresh_op_client_secrets
    fi
    if [ -f "${SECRETS_CACHE}/${USER}.op-secrets.zsh" ]; then
        source "${SECRETS_CACHE}/${USER}.op-secrets.zsh"
    fi

    # Bring in all the secrets
    function refresh_shell_secrets() {
        op ${op_config} inject --force --in-file "${SECRETS_SRC_DIR}/secrets.zsh" --out-file "${SECRETS_CACHE}/${USER}.secrets.zsh" > /dev/null
        source "${SECRETS_CACHE}/${USER}.secrets.zsh"
    }
    if src-newer-or-dest-missing "${SECRETS_SRC_DIR}/secrets.zsh" "${SECRETS_CACHE}/${USER}.secrets.zsh"; then
        refresh_shell_secrets
    fi
    if [ -f "${SECRETS_CACHE}/${USER}.secrets.zsh" ]; then
        source "${SECRETS_CACHE}/${USER}.secrets.zsh"
    fi

    function refresh_mcpservers_secret() {
        op ${op_config} inject --force --in-file "${SECRETS_SRC_DIR}/mcpservers.json" --out-file "${SECRETS_CACHE}/${USER}.mcpservers.json" > /dev/null
    }
    if src-newer-or-dest-missing "${SECRETS_SRC_DIR}/mcpservers.json" "${SECRETS_CACHE}/${USER}.mcpservers.json"; then
        refresh_mcpservers_secret
    fi

    # Set up SSH auth socket for 1Password SSH agent
    _setup_ssh_auth_sock
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

# Register hook - after plugins so secrets are available to post-plugin hooks
zdot_hook_register after-secrets _op_init
