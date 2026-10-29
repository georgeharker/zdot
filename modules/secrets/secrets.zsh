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
#   - _op_get_mode: resolves the auth mode (service-account / login /
#     lazy-login) — see Auth Modes below
#   - _op_is_login: true in either login mode
#   - _op_get_login_accounts: reads ':zdot:secrets:op login-accounts' into
#     $reply (login-mode multi-account support; plain account shortnames)
#   - _op_account_arg: resolves a shortname to the identifier to pass to op
#     (--account/signin/whoami) via ':zdot:secrets:op:<name>' account-url,
#     falling back to the shortname itself
#   - _op: op WITH auth — signs in first if needed (lazy check, re-ask when
#     interactive), then runs op; every op call outside the sign-in
#     machinery goes through it
#   - _op_noauth: op WITHOUT auth — only for whoami/signin/account forget
#   - _op_require_session: refresh commands' "make sure op is usable now"
#     (eager or lazy); re-asks via _op_reauth when interactive
#   - _op_may_prompt / _op_reauth: prompt policy (interactive, not startup)
#     and the warn → sign in (_op_auth_person) → re-check step
#   - _op_ensure_session: lazy-login's deferred check — startup skips it and
#     the first real op call runs it; state in _ZDOT_OP_SESSION
#   - _op_whoami: whoami for a shortname (or the default account), output
#     passed through
#   - _op_logged_in: quiet yes/no form of _op_whoami
#   - _op_signin: sign one account in (optionally --headless), eval the
#     session it prints, confirm with whoami — shared by the startup check
#     and _op_auth_person
#   - _op_auth_person: sign a PERSON in to one account, interactively (no_op,
#     first-run prompt, announce, verify, account-url hint) — used by op_auth
#     in the login modes and by op_identity's service-account half
#   - _op_sa_token_ok: service-account mode — is a working token available
#     (loaded from the cache if this shell lacks it)?
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
#   - op_auth: sign in (interactive only). Login modes: signs people in —
#     every login-accounts entry, or the one named. Service-account mode:
#     uses the token if it works, otherwise errors pointing at op_identity
#     (it never creates one). --reset forgets accounts and drops cached
#     credentials first.
#   - op_identity: establish this machine's 1Password identity — dispatches
#     by auth mode to its two halves (same file): _op_identity_service_account
#     (create/choose the SA, inject the token) / _op_identity_login (sign the
#     sessions in); sets _ZDOT_OP_ACTIVE
#   - op_refresh: old name for op_identity
#   - op_multi_inject: resolve an account-TAGGED template (op-personal://…)
#     with one inject pass per account; all-or-nothing; never sources
#   - op_inject_template: shared inject ROUTER (tagged → op_multi_inject,
#     plain → op inject) — THE place the plain inject line lives — consumed
#     by refreshers here and in the mcp module, so auth-mode nuance lives
#     in exactly one spot
#   - refresh_shell_secrets: Refreshes shell environment secrets
#
# Global State:
#   - _ZDOT_OP_ACTIVE: 1 when 1Password is set up for use — SA token loaded,
#     or (login) every account signed in, or (lazy-login) configured but not
#     yet checked. Other modules gate on this before using op.
#   - _ZDOT_OP_SESSION: lazy-login only (empty otherwise) — pending / ok /
#     failed; see _op_ensure_session.
#
# Auth Modes:
#   zstyle ':zdot:secrets:op' mode service-account|login|lazy-login
#   - service-account (default): the machine's identity is a service-account
#     token, cached in $USER.op-secrets.zsh and good for the whole session.
#     op_identity creates or chooses the account and (re)injects the token.
#   - login (machines without service accounts, e.g. work): the identity is
#     a set of signed-in personal/biometric sessions, checked per account at
#     startup. The op-secrets template, token cache and
#     OP_SERVICE_ACCOUNT_TOKEN are ignored entirely; op_auth signs people in.
#   - lazy-login (recommended over login): the same sessions, checked at the
#     first op call that's actually needed. App integration authorizes per
#     terminal tab and per account, so login's startup check costs a Touch
#     ID prompt per account in every new tab; lazy-login only prompts when
#     a tab needs op.
#   Multi-account login: refs in the shell-secrets template are account-
#   TAGGED — op-personal://…, op-allenai://… — and op_multi_inject resolves
#   them one account at a time (sed op-<acct>:// → op:// | op inject
#   --account <acct>; one pipeline for 1–2 accounts, a loop beyond). op:// refs carry no account
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
#     Then set zstyles to override vault names used by op_identity:
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
# Lazy-mode session state (see _op_ensure_session). Empty outside lazy mode,
# which leaves every op call exactly as it was.
typeset -g _ZDOT_OP_SESSION=""

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
#   'service-account' — cached SA token, good for the whole session (default)
#   'login'           — personal/biometric sessions, checked at startup
#   'lazy-login'      — the same sessions, checked at the first op call
#                       that's actually needed (no prompt in a tab whose
#                       caches are up to date)
# Unset/empty falls back to 'service-account'; unknown values warn and fall
# back too — never an error that blocks secrets loading.
_op_get_mode() {
    local mode
    if zstyle -s ':zdot:secrets:op' mode mode && [[ -n "$mode" ]]; then
        case "$mode" in
            service-account|login|lazy-login) REPLY=$mode; return 0 ;;
            *) zdot_warn "secrets: unknown ':zdot:secrets:op' mode '$mode' (want 'service-account', 'login' or 'lazy-login') — using service-account" ;;
        esac
    fi
    REPLY='service-account'
}

# Is this one of the login modes (login or lazy-login)?
_op_is_login() {
    _op_get_mode
    [[ "$REPLY" == login || "$REPLY" == lazy-login ]]
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

# ── Running op: two entry points ──────────────────────────────────────────
#   _op          op WITH auth: makes sure you're signed in first (lazy-mode
#                check, re-ask when allowed), then runs op. Use this.
#   _op_noauth   op WITHOUT auth: runs op directly. Only for the sign-in
#                machinery itself (whoami, signin, account forget), which
#                is what _op's auth step is built from.
# Both add the resolved config args (`--config <real user's op dir>` under
# sudo, via op_get_config_args).
_op() {
    _op_ensure_session || return 1
    _op_noauth "$@"
}

_op_noauth() {
    local -a op_config
    op_config=(${(f)"$(op_get_config_args)"})
    command op "${op_config[@]}" "$@"
}

# The auth step behind _op. Acts only in lazy login mode, where startup
# marked 1Password set up (_ZDOT_OP_ACTIVE=1) without checking the sessions:
#   ""       not lazy: nothing to do, op behaves as before
#   pending  check now (headless; Touch ID may appear) → ok, or re-ask
#   ok       nothing to do
#   failed   interactive, outside startup: check again, then re-ask;
#            otherwise refuse without calling op (no prompt per command),
#            with a hint unless this is startup
_op_ensure_session() {
    case "$_ZDOT_OP_SESSION" in
        ""|ok) return 0 ;;
        failed)
            if ! _op_may_prompt; then
                [[ -z "${_ZDOT_OP_NOPROMPT:-}" ]] \
                    && zdot_warn "secrets: not signed in to 1Password; run op_identity"
                return 1
            fi ;;
    esac
    _op_login_check && return 0
    _op_reauth
}

# For the refresh commands (refresh_shell_secrets, refresh_mcpservers_secret):
# make sure op is usable now, in either login mode — eager or lazy. When a
# person ran the command (interactive, outside startup) a signed-out account
# is re-asked for via _op_reauth. Service-account mode: the token either
# loaded or it didn't; re-asking would mean op_identity's create-or-choose
# service-account prompts, so it only warns (startup has its own warning).
_op_require_session() {
    if ! _op_is_login; then
        (( _ZDOT_OP_ACTIVE )) && return 0
        [[ -z "${_ZDOT_OP_NOPROMPT:-}" && ! -f "$(op_get_config_dir)/no_op" ]] \
            && zdot_warn "secrets: 1Password service-account token not loaded; run op_identity"
        return 1
    fi
    [[ -n "$_ZDOT_OP_SESSION" ]] && { _op_ensure_session; return }
    (( _ZDOT_OP_ACTIVE )) && return 0          # eager, startup check passed
    [[ -n "${_ZDOT_OP_NOPROMPT:-}" ]] && return 1   # startup warns on its own
    _op_login_check && return 0
    _op_reauth
}

# May we prompt? Interactive shell, and not inside a startup path — startup
# callers (_op_init, mcp's init) set _ZDOT_OP_NOPROMPT as a local, which
# everything they call can see.
_op_may_prompt() {
    [[ $_ZDOT_IS_INTERACTIVE -eq 1 && -z "${_ZDOT_OP_NOPROMPT:-}" ]]
}

# The check just failed ($reply = signed-out shortnames). When we may
# prompt: warn, sign each one in via op_auth, check again. Otherwise warn
# with the op_identity hint. Silent on no_op machines. rc 0 when signed in.
_op_reauth() {
    [[ -f "$(op_get_config_dir)/no_op" ]] && return 1
    local -a out=("${reply[@]}")
    if ! _op_may_prompt; then
        zdot_warn "secrets: not signed in to 1Password: ${(j:, :)out}; run op_identity"
        return 1
    fi
    zdot_warn "secrets: not signed in to 1Password: ${(j:, :)out} — signing in"
    local a
    for a in "${out[@]}"; do
        [[ "$a" == default ]] && a=""
        _op_auth_person "$a"
    done
    _op_login_check && return 0
    zdot_warn "secrets: still not signed in to 1Password: ${(j:, :)reply}; run op_identity"
    return 1
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
    _op_noauth whoami "${acct[@]}"
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
        out=$(_op_noauth signin "${acct[@]}" < /dev/null 2>/dev/null) || return 1
    else
        out=$(_op_noauth signin "${acct[@]}") || return 1
    fi
    [[ -n "$out" ]] && eval "$out"
    _op_logged_in "$name"
}

# Sign a PERSON in to one account (empty: the default account) — the
# interactive core of op_auth, also used by op_identity's service-account
# half, which needs a person signed in to create or choose the account.
# Honors no_op, offers the first-run "Set up 1Password?" prompt, announces
# the account by shortname, signs in and verifies, and on failure prints
# the account-url hint. Interactive shells only. rc 0 when signed in.
_op_auth_person() {
    [[ $_ZDOT_IS_INTERACTIVE -eq 1 ]] || return 1
    local account=${1:-} op_config_dir option
    op_config_dir=$(op_get_config_dir)
    [[ -f "${op_config_dir}/no_op" ]] && return 1

    if [[ ! -f "${op_config_dir}/config" ]]; then
        printf "Set up 1Password? [Y/n/c] "
        read -r -k 1 option
        [[ "$option" = $'\n' ]] || echo
        case "$option" in
            [yY$'\n']) ;;
            [nN])
                mkdir -p "${op_config_dir}"
                touch "${op_config_dir}/no_op"
                return 1
                ;;
            *)
                echo "You will be asked at next login"
                return 1
                ;;
        esac
    fi

    _op_logged_in "$account" && return 0
    printf "Signing into 1Password: %s\n" "${account:-default account}"
    _op_signin "$account" && return 0
    echo "1Password: sign-in did not take for '${account:-default}'"
    if [[ -n "$account" ]]; then
        _op_account_arg "$account"
        if [[ "$REPLY" == "$account" ]]; then
            echo "  '$account' is not a CLI shorthand — map it:"
            echo "    zstyle ':zdot:secrets:op:$account' account-url <address|email|uuid>"
        fi
    fi
    return 1
}

# Service-account mode: is a working token available? Loads it from the
# token cache when this shell doesn't have it, and makes sure it's exported
# (op_identity unexports it while it signs a person in). rc 0 when `op
# whoami` accepts it.
_op_sa_token_ok() {
    if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
        typeset -A _se
        _op_get_secrets_env && _se=("${reply[@]}")
        local cache="${_se[cache]}/${USER}.op-secrets.zsh"
        [[ -f "$cache" ]] && source "$cache"
    fi
    [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] || return 1
    export OP_SERVICE_ACCOUNT_TOKEN
    _op_logged_in
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
        [[ -n "$_ZDOT_OP_SESSION" ]] && _ZDOT_OP_SESSION=failed
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
        [[ -n "$_ZDOT_OP_SESSION" ]] && _ZDOT_OP_SESSION=ok
        return 0
    fi
    _ZDOT_OP_ACTIVE=0
    [[ -n "$_ZDOT_OP_SESSION" ]] && _ZDOT_OP_SESSION=failed
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
    # Startup never prompts: everything called from here sees this local
    # (_op_may_prompt) and only warns.
    local _ZDOT_OP_NOPROMPT=1

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
    _ZDOT_OP_SESSION=""
    if [[ "$op_mode" == lazy-login && ! -f "$(op_get_config_dir)/no_op" ]]; then
        # Lazy login: set up, sessions not checked. Nothing here calls
        # op; the first op call that is actually needed (a template newer
        # than its cache, or a command you run) checks via _op_ensure_session.
        _ZDOT_OP_ACTIVE=1
        _ZDOT_OP_SESSION=pending
    elif [[ "$op_mode" == login || "$op_mode" == lazy-login ]]; then
        # Login (or lazy-login on a no_op machine): no prompts at startup (the check only self-heals
        # headlessly); op_identity is the interactive recovery path. Remember
        # who is signed out for the warning below.
        _op_login_check || signed_out=("${reply[@]}")
    else
        # Service-account mode (back-compat): refresh the token cache if the
        # template is newer, then source it.
        if zdot_is_newer_or_missing "${secrets_src_dir}/op-secrets.zsh" "${secrets_cache}/${USER}.op-secrets.zsh"; then
            op_identity
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
        && { (( ${#signed_out} )) || [[ -f "$template" || -f "$cache_file" ]] } \
        && [[ -o interactive ]]; then
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
        zdot_warn "secrets: ${cause} — ${loaded}; run op_identity, then refresh_shell_secrets"
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
