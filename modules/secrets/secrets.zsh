#!/usr/bin/env zsh
# op: 1Password secrets management
#
# This module manages 1Password integration for secrets and SSH authentication.
# It runs in both interactive and noninteractive contexts, but interactive prompts
# are guarded to only run in interactive shells.
#
# Inline Functions:
#   - _op_get_secrets_env: resolves the shared secrets env (paths + profile
#     suffix) into $reply as a flat name/value pair list — the SINGLE place
#     these derivations live; consumed by _op_init, the autoloaded refresh
#     functions, and the mcp module
#   - _op_get_mode: resolves the auth mode (login / service-account) — see
#     Auth Modes below
#   - _op_get_login_accounts: reads ':zdot:secrets:op login-accounts' into
#     $reply (login-mode multi-account support; plain account shortnames)
#   - _op_account_arg: resolves a shortname to the identifier to pass to op
#     (--account/signin/whoami) via ':zdot:secrets:op:<name>' account-url,
#     falling back to the shortname itself
#   - _op: runs op with the resolved config args — every op call goes
#     through it
#   - _op_whoami: whoami for a shortname (or the default account), output
#     passed through
#   - _op_logged_in: quiet yes/no form of _op_whoami
#   - _op_signin: sign one account in (optionally --headless), eval the
#     session it prints, confirm with whoami — shared by the startup check
#     and op_auth
#   - _op_login_check: login-mode viability per account (no prompts; one
#     headless signin attempt each; signed-out names returned in $reply)
#   - _op_login_feedback: one status line per signed-in account
#   - _setup_ssh_auth_sock: Sets up SSH_AUTH_SOCK for 1Password agent
#   - _op_init: Module initialization, orchestrates secret loading
#
# Autoloaded Functions (in functions/):
#   - op_get_config_dir: Returns op config directory path via stdout
#   - op_get_config_args: Returns op config arguments via stdout (one per line)
#   - op_get_vault_config: Reads vault names from zstyle with defaults
#   - op_auth: sign-in building block (interactive only): signs in one
#     account, or walks every login-accounts entry; --reset forgets accounts
#     and drops cached credentials first. Called by op_refresh when a human
#     is needed.
#   - op_refresh: keep this machine's 1Password credential current —
#     dispatches by auth mode to its two halves (same file):
#     _op_refresh_service_account (SA token) / _op_refresh_login (sessions);
#     sets _ZDOT_OP_ACTIVE
#   - op_multi_inject: resolve an account-TAGGED template (op-personal://…)
#     with one piped inject pass per account; all-or-nothing; never sources
#   - op_inject_template: shared inject ROUTER (tagged → op_multi_inject,
#     plain → op inject) — THE place the plain inject line lives — consumed
#     by refreshers here and in the mcp module, so auth-mode nuance lives
#     in exactly one spot
#   - refresh_shell_secrets: Refreshes shell environment secrets
#
# Global State:
#   - _ZDOT_OP_ACTIVE: 1 when 1Password is authenticated and usable — in
#     EITHER auth mode (see _op_get_mode). Other modules gate on this before
#     using op.
#
# Auth Modes:
#   zstyle ':zdot:secrets:op' mode login|service-account
#   - service-account (default; back-compat): viability comes from the cached
#     $USER.op-secrets.zsh token; op_refresh manages account creation/refresh.
#   - login (for machines without service accounts, e.g. work): viability is
#     `op whoami` (a signed-in personal/biometric session). The op-secrets
#     template, token cache, and OP_SERVICE_ACCOUNT_TOKEN are ignored
#     entirely; sign-in is established interactively via op_auth.
#   Multi-account login: refs in the shell-secrets template are account-
#   TAGGED — op-personal://…, op-allenai://… — and op_multi_inject resolves
#   them one account at a time (sed op-<acct>:// → op:// | op inject
#   --account <acct>, fully piped and chained). op:// refs carry no account
#   segment and bare op commands FAIL when >1 account is available — the tag
#   is what selects the account per pass. ALL tagged accounts must be signed
#   in or the refresh errors (nothing written); raw op:// refs need
#     zstyle ':zdot:secrets:op' default-account <shorthand>
#   (the default pass runs first; no default → raw refs rejected).
#   login-accounts (next) is the viability authority; tagging is the inject
#   authority. Single-account / SA machines: plain refs, nothing to tag.
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

# Resolve the shared secrets environment: paths and the op profile suffix.
# Reads ':zdot:secrets:op profile' at CALL time (config-driven, like
# zdot_verify_tools_zstyle) and returns a flat NAME/VALUE pair list in $reply
# (always even length):
#   src_dir - source directory for secret templates
#   cache   - cache directory for processed secrets (no trailing slash;
#             interpolate "${cache}/${USER}.…" — canonical; do NOT re-derive
#             these paths elsewhere, the mcp module consumed to duplicate them)
#   suffix  - "-<profile>" when a profile is configured, else '' (an EMPTY word,
#             which consumers must not confuse with an unset pair)
# Consumer pattern (copy before any other reply/REPLY-setting call):
#   typeset -A _se
#   _op_get_secrets_env && _se=("${reply[@]}")
#   local secrets_src_dir="${_se[src_dir]}" secrets_cache="${_se[cache]}" \
#       op_secrets_profile_suffix="${_se[suffix]}"
_op_get_secrets_env() {
    local op_secrets_profile
    # A secrets-specific profile wins (explicit — even empty counts as
    # configured "none"); the generic :zdot:profile name (profiles module)
    # is the backstop when the secrets-specific one is unset.
    if ! zstyle -s ':zdot:secrets:op' profile op_secrets_profile; then
        zdot_profile_get
        op_secrets_profile="$REPLY"
    fi
    local op_secrets_profile_suffix=""
    # NOTE: the variable MUST be expanded here — zsh [[ ]] args do not expand,
    # so a bare "[[ -n op_secrets_profile ]]" tests the literal string and is
    # always true (the old helper had exactly that bug behind its C019 marker:
    # a bare machine got a "-" suffix and looked for secrets-.zsh).
    if [[ -n "$op_secrets_profile" ]]; then
        op_secrets_profile_suffix="-${op_secrets_profile}"
    fi
    reply=(
        src_dir "${XDG_CONFIG_HOME:-${HOME}/.config}/secrets"
        cache   "${XDG_CACHE_HOME:-$HOME/.cache}/secrets"
        suffix  "${op_secrets_profile_suffix}"
    )
}

# Resolve the 1Password auth mode into $REPLY:
#   'login'           — personal/biometric session (machines without service
#                       accounts); viability = `op whoami`
#   'service-account' — cached SA token (default; back-compat)
# Unset/empty falls back to 'service-account'; unknown values warn and fall
# back too — never an error that blocks secrets loading.
_op_get_mode() {
    local mode
    if zstyle -s ':zdot:secrets:op' mode mode && [[ -n "$mode" ]]; then
        case "$mode" in
            login)           REPLY='login'; return 0 ;;
            service-account) REPLY='service-account'; return 0 ;;
            *) zdot_warn "secrets: unknown ':zdot:secrets:op' mode '$mode' (want 'login' or 'service-account') — using service-account" ;;
        esac
    fi
    REPLY='service-account'
}

# Multi-account support: account shorthands for login mode into $reply.
# Read from ':zdot:secrets:op login-accounts' (e.g. personal allenai); an
# EMPTY $reply (zstyle unset / empty) means "single default account" — the
# back-compat bare-op behavior. When set, EVERY per-account op call passes
# --account (bare op fails with more than one account available).
_op_get_login_accounts() {
    reply=()
    local -a accts
    zstyle -a ':zdot:secrets:op' login-accounts accts || return 0
    reply=("${accts[@]}")
}

# Resolve the argument for op --account / signin / whoami for a shortname,
# from a per-account context (one zstyle line per account):
#   zstyle ':zdot:secrets:op:personal' account-url my.1password.com
# Per-account CONTEXTS, not repeated calls on one context: a second
# `zstyle ':zdot:secrets:op' account-url …` REPLACES the first rather than
# adding to it. Falls back to the shortname itself (CLI shorthands are
# valid --account values on their own). Sets $REPLY.
_op_account_arg() {
    zstyle -s ":zdot:secrets:op:$1" account-url REPLY && [[ -n "$REPLY" ]] && return 0
    REPLY=$1
}

# Run op with the resolved config args: `--config <real user's op dir>`
# under sudo (op_get_config_args), nothing otherwise. Every op call in the
# module goes through here, so none can quietly use the wrong config.
_op() {
    local -a op_config
    op_config=(${(f)"$(op_get_config_args)"})
    command op "${op_config[@]}" "$@"
}

# `op whoami` for one account, output passed through. <name> is a
# login-accounts shortname (resolved via _op_account_arg), or empty for the
# default account. Fails cleanly — no prompt, no hang — when signed out.
_op_whoami() {
    local -a acct=()
    if [[ -n "${1:-}" ]]; then
        _op_account_arg "$1"
        acct=(--account "$REPLY")
    fi
    _op whoami "${acct[@]}"
}

# Is <name> (or the default account) signed in? Quiet form of _op_whoami.
_op_logged_in() {
    _op_whoami "$@" &> /dev/null
}

# Sign one account in and confirm it took. <name> as for _op_whoami.
#   --headless  no stdin and no error output: the startup self-heal. App
#               integration completes silently; anything that would prompt
#               fails fast instead of hanging the shell.
# signin prints session exports for CLI-only accounts; they are eval-ed here
# so the session exists in this shell (app integration prints nothing).
# rc 0 only when whoami succeeds afterwards.
_op_signin() {
    local headless=0
    if [[ "${1:-}" == --headless ]]; then
        headless=1
        shift
    fi
    local name=${1:-} out
    local -a acct=()
    if [[ -n "$name" ]]; then
        _op_account_arg "$name"
        acct=(--account "$REPLY")
    fi
    if (( headless )); then
        out=$(_op signin "${acct[@]}" < /dev/null 2>/dev/null) || return 1
    else
        out=$(_op signin "${acct[@]}") || return 1
    fi
    [[ -n "$out" ]] && eval "$out"
    _op_logged_in "$name"
}

# Login-mode viability check, run per configured account. No interactive
# prompts: an account whose whoami fails gets one headless signin attempt
# (_op_signin --headless). Honors the no_op sentinel; touches none of the
# service-account machinery.
# Contract (matches the all-or-nothing inject):
#   rc 0      — EVERY configured account is signed in; _ZDOT_OP_ACTIVE=1
#   rc 1      — at least one is not;                   _ZDOT_OP_ACTIVE=0
#   $reply    — the shortnames still signed out (empty iff rc 0)
_op_login_check() {
    local op_config_dir
    op_config_dir=$(op_get_config_dir)
    if [[ -f "${op_config_dir}/no_op" ]]; then
        reply=()
        _ZDOT_OP_ACTIVE=0
        return 1
    fi
    local -a accounts signed_out
    accounts=(); signed_out=()
    _op_get_login_accounts
    accounts=("${reply[@]}")
    local a
    if (( ${#accounts} == 0 )); then
        # Single default account (no login-accounts configured)
        _op_logged_in || signed_out+=(default)
    else
        for a in "${accounts[@]}"; do
            _op_logged_in "$a" && continue
            _op_signin --headless "$a" && continue
            signed_out+=("$a")
        done
    fi
    reply=("${signed_out[@]}")
    if (( ${#signed_out} == 0 )); then
        _ZDOT_OP_ACTIVE=1
        return 0
    fi
    _ZDOT_OP_ACTIVE=0
    return 1
}

# Post-sign-in feedback: one line per signed-in account (bare mode: one
# line for the default account).
_op_login_feedback() {
    local -a accounts
    _op_get_login_accounts
    accounts=("${reply[@]}")
    local line a
    if (( ${#accounts} == 0 )); then
        line=$(_op_whoami 2>/dev/null) && zdot_info "secrets: 1Password session OK — ${line}"
        return 0
    fi
    for a in "${accounts[@]}"; do
        line=$(_op_whoami "$a" 2>/dev/null) || continue
        zdot_info "secrets: '$a' session OK — ${line}"
    done
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

    # Secrets environment — one resolver, named keys (see _op_get_secrets_env)
    typeset -A _se
    _op_get_secrets_env && _se=("${reply[@]}")
    local secrets_src_dir="${_se[src_dir]}" secrets_cache="${_se[cache]}" \
        op_secrets_profile_suffix="${_se[suffix]}"
    [[ ! -d "${secrets_cache}" ]] && mkdir -p "${secrets_cache}"

    # ── Authentication / viability (mode-dependent) ─────────────────────────
    _ZDOT_OP_ACTIVE=0
    local op_mode
    _op_get_mode && op_mode=$REPLY
    local -a signed_out=()
    if [[ "$op_mode" == login ]]; then
        # Login mode: no prompts at startup (the check only self-heals
        # headlessly); op_refresh is the interactive recovery path. Remember
        # who is signed out for the warning below.
        _op_login_check || signed_out=("${reply[@]}")
    else
        # Service-account mode (back-compat): refresh the token cache if the
        # template is newer, then source it.
        if zdot_is_newer_or_missing "${secrets_src_dir}/op-secrets.zsh" "${secrets_cache}/${USER}.op-secrets.zsh"; then
            op_refresh
        fi
        if [[ -f "${secrets_cache}/${USER}.op-secrets.zsh" ]]; then
            source "${secrets_cache}/${USER}.op-secrets.zsh"
            # Usable if we have a token, or op is actually signed in
            [[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ]] && _ZDOT_OP_ACTIVE=1
            _op_logged_in && _ZDOT_OP_ACTIVE=1
        fi
    fi
        
    # ── Shell secrets: one template, one cache file ──────────────────────────
    # Refresh when op is usable and the template changed. Source whatever
    # cache exists either way: when op is not usable it is the last good
    # copy, possibly stale, and the warning says so. One warning per cause;
    # never on machines that opted out (no_op sentinel).
    local template="${secrets_src_dir}/secrets${op_secrets_profile_suffix}.zsh"
    local cache_file="${secrets_cache}/${USER}.secrets.zsh"
    local template_changed=0
    [[ -f "$template" ]] && zdot_is_newer_or_missing "$template" "$cache_file" \
        && template_changed=1
    if (( _ZDOT_OP_ACTIVE )); then
        if (( template_changed )); then
            refresh_shell_secrets
        else
            zdot_verbose "secrets: cache is up to date, skipping refresh"
        fi
    elif [[ ! -f "$(op_get_config_dir)/no_op" ]] \
        && { (( ${#signed_out} )) || [[ -f "$template" || -f "$cache_file" ]] }; then
        local cause loaded
        if (( ${#signed_out} )); then
            cause="not signed in to 1Password: ${(j:, :)signed_out}"
        else
            cause="1Password is not active"
        fi
        if [[ -f "$cache_file" ]]; then
            loaded="using cached secrets"
            (( template_changed )) && loaded+=" (older than the template)"
        else
            loaded="no cached secrets to load"
        fi
        zdot_warn "secrets: ${cause} — ${loaded}; run op_refresh, then refresh_shell_secrets"
    fi
    [[ -f "$cache_file" ]] && source "$cache_file"

    # Set up SSH auth socket (works in both interactive and noninteractive)
    _setup_ssh_auth_sock
}

# Register hook — requires bootstrap-ready and the secrets-configure group,
# provides secrets-loaded.  Any user hook registered with --group secrets-configure
# is guaranteed to run before this.
# Runs in both interactive and noninteractive modes;
# interactive prompts only happen in interactive shells due to function guards.
zdot_register_hook _op_init interactive noninteractive \
    --requires bootstrap-ready \
    --requires profiles-configured \
    --requires-tool op \
    --requires-group secrets-configure \
    --provides secrets-loaded
