#!/usr/bin/env zsh
# Harness: secrets module auth-mode helpers (_op_get_mode / op_identity)
# and the login-mode dispatch in op_identity. Cases:
#   mode resolution (unset/empty defaults to 'service-account'; 'login'
#   recognized; unknown values fall back with a warn) and login-mode
#   viability via a FAKE `op` binary on PATH:
#     FAKE_OP_MODE=success  — whoami succeeds                   → usable
#     FAKE_OP_MODE=fail     — whoami fails, noninteractive      → not usable
#     FAKE_OP_MODE=recover  — whoami fails, `op signin` fixes   → usable
#                             (exercises the interactive op_auth retry path)
#     plus the no_op sentinel short-circuit, the op_identity dispatch, the
#     PASSIVE startup check (_op_init never prompts — even when signed out),
#     and the account-feedback line on the manual recovery path, plus
#     multi-account login (login-accounts viability, account-tagged
#     op-<acct>:// refs resolved by op_multi_inject in pipe mode,
#     default-account raw).
# No real 1Password involved. Each case runs in its own `zsh -f` subshell.
# Run:  zsh -f tests/test_op_mode.zsh

emulate -L zsh

ZDOT_ROOT="${${(%):-%x}:a:h:h}"

# Fake op binary: honors FAKE_OP_MODE; parses flags (--account/--in-file/
# --out-file) like the real CLI.
# IMPORTANT: shebang is /bin/sh, NOT env zsh — an env-zsh script re-sources
# ~/.zshenv on every exec, which fully initializes zdot and (with mode=login
# in ~/.zshenv_local) recurses via _op_init → op whoami → exec op → … That
# was the observed “hang” in ad-hoc runs; /bin/sh keeps the fake inert.
# Modes:
#   success — every whoami passes | fail — none pass
#   partial — whoami passes only for accounts listed in FAKE_OK_ACCOUNTS
#   recover — passes only after a signin (marker per account in FAKE_STATE_DIR)
# A successful whoami prints an account line (feedback cases). With
# FAKE_CALL_LOG set, every invocation appends its full arg list; inject
# copies --in-file to --out-file (single-account path), pipes stdin→stdout
# (multi chain passes), and fails per-account via FAKE_INJECT_FAIL_ACCOUNTS.
fake_bin="$(mktemp -d)"
print -r -- '#!/bin/sh
[[ -n "${FAKE_CALL_LOG:-}" ]] && printf "%s\n" "$*" >> "${FAKE_CALL_LOG}"
sub="$1"; shift
account=""; in_file=""; out_file=""; account_left=()
while [ $# -gt 0 ]; do
    case "$1" in
        --account) account="$2"; shift 2 ;;
        --in-file) in_file="$2"; shift 2 ;;
        --out-file) out_file="$2"; shift 2 ;;
        --force) shift ;;
        *) account_left+=("$1"); shift ;;
    esac
done
account_key="signed-in"
[[ -n "$account" ]] && account_key="signed-in-${account}"
account_verb=""; account_name=""
[ -n "${account_left[0]:-}" ] && account_verb="${account_left[0]}"
[ -n "${account_left[1]:-}" ] && account_name="${account_left[1]}"
case "$sub" in
    whoami)
        # Like real op: an exported service-account token answers whoami
        # as the service account, whatever --account says.
        if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
            printf "%s\n" "User Type: SERVICE_ACCOUNT"; exit 0
        fi
        case "${FAKE_OP_MODE}" in
            success) printf "%s\n" "Signed in as fake@1password.test"; exit 0 ;;
            partial)
                if [[ -n "$account" && " ${FAKE_OK_ACCOUNTS:-} " == *" ${account} "* ]]; then
                    printf "%s\n" "Signed in as fake@1password.test (${account})"; exit 0
                fi
                exit 1 ;;
            recover)
                if [[ -f "${FAKE_STATE_DIR}/${account_key}" ]]; then
                    printf "%s\n" "Signed in as fake@1password.test"; exit 0
                fi
                exit 1 ;;
            *) exit 1 ;;
        esac ;;
    signin)
        # FAKE_SIGNIN_NEEDS_TTY: refuse the headless form (stdin /dev/null),
        # like an account that can only sign in interactively
        if [ -n "${FAKE_SIGNIN_NEEDS_TTY:-}" ] && [ /dev/fd/0 -ef /dev/null ]; then exit 1; fi
        : > "${FAKE_STATE_DIR}/${account_key}"
        [ -n "${FAKE_SIGNIN_EXPORT:-}" ] && printf "export OP_SESSION_fake=%s\n" "$account"
        exit 0 ;;
    inject)
        if [ -n "$account" ] && [[ " ${FAKE_INJECT_FAIL_ACCOUNTS:-} " == *" ${account} "* ]]; then
            exit 1
        fi
        if [[ -z "$in_file" || -z "$out_file" ]]; then
            cat   # multi chain passes: stdin → stdout
            exit 0
        fi
        if [[ ! -f "$in_file" ]]; then
            exit 1
        fi
        cp "$in_file" "$out_file"
        exit 0 ;;
    account)
        if [[ "$account_verb" == forget ]]; then
            # --all normalizes to a single marker name
            [[ "$account_name" == "--all" ]] && account_name="all"
            : > "${FAKE_STATE_DIR}/forgot-${account_name}"
            exit 0
        fi
        exit 1 ;;
    service-account|item) exit 1 ;;   # login mode must never call these
    *) exit 1 ;;
esac' > "$fake_bin/op"
chmod +x "$fake_bin/op"
export PATH="$fake_bin:$PATH"
export FAKE_STATE_DIR="$(mktemp -d)"


if [[ "${1:-}" == --case ]]; then
    source "${ZDOT_ROOT}/zdot.zsh" || { print -u2 "FAIL: cannot source zdot.zsh"; exit 2 }
    source "${ZDOT_ROOT}/modules/profiles/profiles.zsh" || { print -u2 "FAIL: cannot source profiles module"; exit 2 }
    source "${ZDOT_ROOT}/modules/secrets/secrets.zsh" || { print -u2 "FAIL: cannot source secrets module"; exit 2 }

    typeset -gi _ZDOT_IS_INTERACTIVE=${FAKE_INTERACTIVE:-0}

    # Isolated config dir so the no_op sentinel test can't collide with a real one
    XDG_CONFIG_HOME="$(mktemp -d)"
    XDG_CACHE_HOME="$(mktemp -d)"

    # Module INLINE functions (like _op_get_secrets_env) are defined by the
    # source above; autoloaded ones (op_identity, op_auth…) need fpath + an
    # explicit autoload — zdot_module_autoload_funcs needs more bootstrap
    # state than this harness provides.
    fpath+=("${ZDOT_ROOT}/modules/secrets/functions")
    autoload -Uz op_identity op_refresh op_auth op_get_config_dir op_get_config_args \
        op_get_vault_config op_get_vault_grants refresh_shell_secrets op_multi_inject \
        op_inject_template op_upsert_file op_download_file

    case "$2" in
        default-mode)
            _op_get_mode && [[ "$REPLY" == 'service-account' ]] \
                || { print "RESULT: FAIL (mode '$REPLY' with no zstyle set)"; exit 1 }
            print "RESULT: PASS" ;;

        login-mode)
            zstyle ':zdot:secrets:op' mode login
            _op_get_mode && [[ "$REPLY" == 'login' ]] \
                || { print "RESULT: FAIL (mode '$REPLY' expected 'login')"; exit 1 }
            print "RESULT: PASS" ;;

        unknown-mode-falls-back)
            zstyle ':zdot:secrets:op' mode banana
            _op_get_mode && [[ "$REPLY" == 'service-account' ]] \
                || { print "RESULT: FAIL (unknown mode did not fall back, got '$REPLY')"; exit 1 }
            print "RESULT: PASS" ;;

        empty-mode-falls-back)
            zstyle ':zdot:secrets:op' mode ''
            _op_get_mode && [[ "$REPLY" == 'service-account' ]] \
                || { print "RESULT: FAIL (empty mode did not fall back, got '$REPLY')"; exit 1 }
            print "RESULT: PASS" ;;

        whoami-success-noninteractive)
            export FAKE_OP_MODE=success
            _ZDOT_OP_ACTIVE=9   # sentinel: helper must SET it, not leave it
            OP_SERVICE_ACCOUNT_TOKEN=SENTINEL   # must be untouched by login mode
            zstyle ':zdot:secrets:op' mode login
            op_identity && \
                [[ "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (rc!=0 or _ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE)"; exit 1 }
            [[ "$OP_SERVICE_ACCOUNT_TOKEN" == SENTINEL ]] \
                || { print "RESULT: FAIL (login mode must not touch OP_SERVICE_ACCOUNT_TOKEN)"; exit 1 }
            print "RESULT: PASS" ;;

        whoami-fail-noninteractive)
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode login
            op_identity && { print "RESULT: FAIL (expected rc=1)"; exit 1 }
            [[ "$_ZDOT_OP_ACTIVE" == 0 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 0)"; exit 1 }
            print "RESULT: PASS" ;;

        whoami-fail-interactive-recovers)
            # First whoami fails; op_auth (via fake op `signin`) then fixes it.
            # A config file is required so op_auth skips its setup prompt.
            export FAKE_OP_MODE=recover
            export FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            mkdir -p "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            zstyle ':zdot:secrets:op' mode login
            op_identity && \
                [[ "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (interactive sign-in retry failed, _ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE)"; exit 1 }
            grep -q '^signup$' "${FAKE_CALL_LOG}" \
                && { print "RESULT: FAIL (signin path must be recovery-only)"; exit 1 }
            grep -q '^signin$' "${FAKE_CALL_LOG}" \
                || { print "RESULT: FAIL (op_auth did not attempt signin)"; exit 1 }
            print "RESULT: PASS" ;;

        no-op-sentinel)
            export FAKE_OP_MODE=success   # whoami would succeed — sentinel must gate first
            mkdir -p "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/no_op"
            zstyle ':zdot:secrets:op' mode login
            op_identity && { print "RESULT: FAIL (no_op sentinel ignored)"; exit 1 }
            [[ "$_ZDOT_OP_ACTIVE" == 0 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 0)"; exit 1 }
            print "RESULT: PASS" ;;

        op-refresh-login-dispatch)
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' mode login
            mkdir -p "${XDG_CACHE_HOME}/secrets"
            echo "stale" > "${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"  # SA leftover must survive
            op_identity && \
                [[ "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (op_identity login dispatch, _ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE)"; exit 1 }
            [[ -f "${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh" ]] \
                || { print "RESULT: FAIL (login mode deleted the SA token cache — must not touch it)"; exit 1 }
            print "RESULT: PASS" ;;

        op-refresh-feedback)
            # Manual recovery/print of the signed-in account:
            # op_identity (login half) surfaces `op whoami` output via zdot_info.
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' mode login
            local out
            out=$(op_identity 2>&1) \
                || { print "RESULT: FAIL (op_identity rc=$?)"; exit 1 }
            [[ "$out" == *fake@1password.test* ]] \
                || { print "RESULT: FAIL (no account feedback, got: $out)"; exit 1 }
            print "RESULT: PASS" ;;

        init-login-passive-fail)
            # _op_init at startup must be PASSIVE: signed-out + noninteractive
            # → inactive, a warn, and NO sign-in attempt (no prompts at startup).
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode login
            export HOME="$(mktemp -d)"   # isolate _setup_ssh_auth_sock side effects
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            _ZDOT_OP_ACTIVE=9
            _op_init
            [[ "$_ZDOT_OP_ACTIVE" == 0 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 0)"; exit 1 }
            grep -q 'signin' "${FAKE_CALL_LOG}" \
                && { print "RESULT: FAIL (startup must not attempt signin)"; exit 1 }
            print "RESULT: PASS" ;;

        init-login-passive-ok)
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' profile ''   # deterministic suffix
            export HOME="$(mktemp -d)"
            _ZDOT_OP_ACTIVE=9
            _op_init
            [[ "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 1)"; exit 1 }
            print "RESULT: PASS" ;;

        login-accounts-partial-in)
            # Two configured accounts, one signed in and one that cannot be
            # healed: NOT usable (inject is all-or-nothing), and $reply names
            # exactly the account still signed out.
            export FAKE_OP_MODE=partial FAKE_OK_ACCOUNTS="personal"
            zstyle ':zdot:secrets:op' login-accounts personal allenai
            _ZDOT_OP_ACTIVE=9
            local prc=0
            _op_login_check || prc=$?
            local pout="${reply[*]}"
            [[ "$prc" == 1 && "$_ZDOT_OP_ACTIVE" == 0 && "$pout" == allenai ]] \
                || { print "RESULT: FAIL (rc=$prc active=$_ZDOT_OP_ACTIVE reply='$pout'; want 1/0/allenai)"; exit 1 }
            print "RESULT: PASS" ;;

        login-check-heals-every-account)
            # Both accounts signed out but healable headlessly: the check
            # must attempt signin for EACH (regression: only the first was
            # tried), using the account-url identifier, then pass.
            export FAKE_OP_MODE=recover
            zstyle ':zdot:secrets:op' login-accounts personal allenai
            zstyle ':zdot:secrets:op:personal' account-url my.1password.com
            zstyle ':zdot:secrets:op:allenai' account-url allenai.1password.com
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local hrc=0
            _op_login_check || hrc=$?
            local hout="${reply[*]}"
            [[ "$hrc" == 0 && -z "$hout" ]] \
                || { print "RESULT: FAIL (rc=$hrc reply='$hout'; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            local want
            for want in my.1password.com allenai.1password.com; do
                grep -q "signin --account $want" "$FAKE_CALL_LOG" \
                    || { print "RESULT: FAIL ($want not healed; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            done
            print "RESULT: PASS" ;;

        op-auth-resolves-account-url)
            # op_auth must hand op the account-url identifier, not the
            # shortname (regression: 'found no accounts for filter personal').
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' login-accounts personal
            zstyle ':zdot:secrets:op:personal' account-url my.1password.com
            mkdir -p "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local aout
            aout=$(op_auth 2>&1) \
                || { print -r -- "RESULT: FAIL (op_auth rc=$? out=$aout)"; exit 1 }
            grep -q 'signin --account my.1password.com' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (signin not resolved; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            [[ "$aout" == *"Signing into 1Password: personal"* ]] \
                || { print -r -- "RESULT: FAIL (announce should use the shortname, got: $aout)"; exit 1 }
            print "RESULT: PASS" ;;

        login-accounts-none-in)
            # Two configured accounts, none signed in: not usable, both listed.
            export FAKE_OP_MODE=partial FAKE_OK_ACCOUNTS=""
            zstyle ':zdot:secrets:op' login-accounts personal allenai
            _op_login_check && { print "RESULT: FAIL (expected rc=1)"; exit 1 }
            [[ "$_ZDOT_OP_ACTIVE" == 0 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 0)"; exit 1 }
            [[ "${reply[*]}" == "personal allenai" ]] \
                || { print "RESULT: FAIL (reply='${reply[*]}' expected both)"; exit 1 }
            print "RESULT: PASS" ;;

        init-login-multi)
            # Multi-account startup: tagged refs + a default account for raw
            # refs. All accounts signed in (success mode): merged cache is
            # written and sourced; NO signin attempts at startup (passive).
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' profile ''
            zstyle ':zdot:secrets:op' login-accounts personal allenai
            zstyle ':zdot:secrets:op' default-account personal
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets"
            print 'export PERSONAL_TOKEN="op-personal://Private/Item/f"' > "${XDG_CONFIG_HOME}/secrets/secrets.zsh"
            print 'export AI_TOKEN="op-allenai://Work/Item/f"' >> "${XDG_CONFIG_HOME}/secrets/secrets.zsh"
            print 'export RAW_TOKEN="op://Raw/Item/f"' >> "${XDG_CONFIG_HOME}/secrets/secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            _ZDOT_OP_ACTIVE=9
            _op_init
            [[ "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 1)"; exit 1 }
            [[ "$PERSONAL_TOKEN" == 'op://Private/Item/f' ]] \
                || { print -r -- "RESULT: FAIL (personal token: $PERSONAL_TOKEN)"
                    print -r -- "RESULT: cache: $(cat "${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh" 2>/dev/null | tr '\n' '|')"
                    print -r -- "RESULT: log: $(cat "${FAKE_CALL_LOG:-/dev/null}" 2>/dev/null | tr '\n' '|')"
                    exit 1 }
            [[ "$AI_TOKEN" == 'op://Work/Item/f' ]] \
                || { print "RESULT: FAIL (allenai tag not converted, got '$AI_TOKEN')"; exit 1 }
            [[ "$RAW_TOKEN" == 'op://Raw/Item/f' ]] \
                || { print "RESULT: FAIL (raw ref lost, got '$RAW_TOKEN')"; exit 1 }
            grep -q signin "${FAKE_CALL_LOG}" \
                && { print "RESULT: FAIL (startup must not attempt signin)"; exit 1 }
            print "RESULT: PASS" ;;

        op-multi-pipe-mode)
            # Pipe mode: stdin in, stdout out — composable like op inject.
            # (zdot_error/zdot_warn go to stderr, never the data path.)
            export FAKE_OP_MODE=success
            mkdir -p "${XDG_CONFIG_HOME}/secrets"
            export FAKE_CALL_LOG="$XDG_CACHE_HOME/op-calls.txt"  # fake-vs-real discriminator
            command -v op > "${XDG_CACHE_HOME}/which-op.txt" 2>&1
            local piped
            piped=$(print 'export X="op://Priv/It/f"' | op_multi_inject --default-account personal --force 2>&1) \
                || { print "RESULT: FAIL (pipe mode rc, err: ${piped:q})"; exit 1 }
            [[ "$piped" == 'export X="op://Priv/It/f"' ]] || {
                print -r -- "RESULT: FAIL (pipe output: $piped)"
                print -r -- "RESULT: FAIL (pipe fake-log: $(cat "$FAKE_CALL_LOG" 2>/dev/null))"
                exit 1
            }
            print "RESULT: PASS" ;;

        op-multi-explicit-order)
            # Explicit --account pass list: order taken verbatim; seds for
            # each account's tag compose around the passes. Three accounts,
            # so the passes run one after another (the loop) and the call
            # log order is meaningful — 1–2 passes run as one concurrent
            # pipeline, where log order is a race.
            export FAKE_OP_MODE=success
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}"
            local tpl3="$XDG_CONFIG_HOME/secrets-order.zsh" out3="$XDG_CACHE_HOME/order.zsh"
            print 'export B="op-personal://Priv/D/g"' > "$tpl3"
            print 'export AI="op-allenai://Work/C/f"' >> "$tpl3"
            print 'export G="op-gamma://G/H/i"' >> "$tpl3"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            op_multi_inject -i "$tpl3" -o "$out3" --account allenai --account gamma --account personal \
                || { print "RESULT: FAIL (explicit order rc)"; exit 1 }
            local o
            o=$(<"$out3")
            [[ "$o" == *'op://Work/C/f'* && "$o" == *'op://Priv/D/g'* && "$o" == *'op://G/H/i'* ]] \
                || { print "RESULT: FAIL (conversion, out: $o)"; exit 1 }
            local order
            order=$(grep -o 'inject --account [a-z]*' "$FAKE_CALL_LOG" | awk '{print $3}' | tr '\n' ' ')
            [[ "$order" == "allenai gamma personal " ]] \
                || { print "RESULT: FAIL (explicit pass order not honored: $order)"; exit 1 }
            print "RESULT: PASS" ;;
        op-multi-fallback-names-account)
            # Mid-chain inject failure: pipeline fails silently, fallback
            # replay names the failing account; nothing is written.
            export FAKE_OP_MODE=success FAKE_INJECT_FAIL_ACCOUNTS="allenai"
            export FAKE_CALL_LOG="$XDG_CACHE_HOME/fail-log.txt"
            mkdir -p "${XDG_CONFIG_HOME}/secrets"
            local tpl4="$XDG_CONFIG_HOME/secrets-fail.zsh" out4="$XDG_CACHE_HOME/fail.zsh"
            print 'export P="op-personal://Priv/A/f"' > "$tpl4"
            print "export A=\"op-allenai://Work/C/f\"" >> "$tpl4"
            rm -f "$out4"
            local errf
            errf=$(op_multi_inject -i "$tpl4" -o "$out4" 2>&1) \
                && { print -r -- "RESULT: FAIL (rc=0! out4: $(cat "${out4:-/dev/null}" 2>/dev/null | tr '\n' '|'))"
                    print -r -- "RESULT: log: $(cat "${FAKE_CALL_LOG:-/dev/null}" 2>/dev/null | tr '\n' '|')"
                    exit 1 }
            [[ "$errf" == *allenai* && "$errf" == *pass*"1"* ]] || {
                print -r -- "RESULT: FAIL (fallback should name allenai + pass 1, got: $errf)"
                print -r -- "RESULT: LOG: $(cat "$FAKE_CALL_LOG" 2>/dev/null | tr '\n' '|')"
                print -r -- "RESULT: OUT4: $(cat "$out4" 2>/dev/null | tr '\n' '|')"
                exit 1
            }
            [[ ! -f "$out4" ]] \
                || { print "RESULT: FAIL (out must not be written on failure)"; exit 1 }
            print "RESULT: PASS" ;;

        op-auth-walks-all)
            # op_auth bare + login-accounts set → signs into EVERY account.
            # Both signed out (recover mode): after op_auth, both markers exist.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' login-accounts personal allenai
            mkdir -p "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            op_auth \
                || { print "RESULT: FAIL (op_auth bare rc=$?)"; exit 1 }
            grep -q 'signin --account personal' "${FAKE_CALL_LOG}" || \
                { print "RESULT: FAIL (personal signin missing, log: $(cat "${FAKE_CALL_LOG}"))"; exit 1 }
            grep -q 'signin --account allenai' "${FAKE_CALL_LOG}" || \
                { print "RESULT: FAIL (allenai signin missing, log: $(cat "${FAKE_CALL_LOG}"))"; exit 1 }
            print "RESULT: PASS" ;;

        op-auth-reset)
            # --reset: cached SA key removed, accounts forgotten via account
            # list (from the fake table), then the fresh sign-in walk runs.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' login-accounts personal allenai
            mkdir -p "${XDG_CONFIG_HOME}/op" "${XDG_CACHE_HOME}/secrets"
            : > "${XDG_CONFIG_HOME}/op/config"
            : > "${FAKE_STATE_DIR}/signed-in-personal"
            : > "${FAKE_STATE_DIR}/signed-in-allenai"
            print 'export OP_SERVICE_ACCOUNT_TOKEN=x' > "${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"
            OP_SERVICE_ACCOUNT_TOKEN=sentinel
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local reset_out
            reset_out=$(op_auth --reset 2>&1)
            local reset_rc=$?
            [[ "$reset_rc" == 0 ]] \
                || { print -r -- "RESULT: FAIL (reset rc=$reset_rc out=$reset_out)"; exit 1 }
            [[ -f "$FAKE_STATE_DIR/forgot-all" ]] \
                || { print -r -- "RESULT: FAIL (no forgot marker)"; exit 1 }
            [[ ! -f "${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh" ]] \
                || { print -r -- "RESULT: FAIL (SA token cache survived)"; exit 1 }
            grep -q 'account forget --all' "${FAKE_CALL_LOG}" \
                || { print -r -- "RESULT: FAIL (forget --all not issued)"; exit 1 }
            print "RESULT: PASS" ;;

        account-url-map)
            # Account-URL zstyle: the shortname resolves to the identifier op
            # actually targets (fake whoami only passes for the URL form).
            export FAKE_OP_MODE=partial FAKE_OK_ACCOUNTS="my.1password.com"
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' login-accounts personal
            zstyle ':zdot:secrets:op:personal' account-url my.1password.com
            mkdir -p "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local check_rc signed_out
            export FAKE_CALL_LOG="$XDG_CACHE_HOME/check-log.txt"
            : > "$FAKE_CALL_LOG"
            _op_login_check && check_rc=0 || check_rc=$?
            signed_out="${reply[*]}"   # snapshot: reply is clobbered by later calls
            _op_account_arg personal && local probe_id=$REPLY
            [[ "$check_rc" == 0 && -z "$signed_out" && "$probe_id" == "my.1password.com" ]] \
                || { export FAKE_CALL_LOG="$XDG_CACHE_HOME/check-log.txt"
                    print -r -- "RESULT: FAIL (rc=$check_rc signed_out='$signed_out' probe=$probe_id; calls=$(cat "${FAKE_CALL_LOG}" 2>/dev/null | tr '\n' '|'))"; exit 1 }
            print "RESULT: PASS" ;;

        op-multi-signedout-error)
            # One tagged account signed out → error, NOTHING written.
            export FAKE_OP_MODE=partial FAKE_OK_ACCOUNTS="personal"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}"
            local tpl="$XDG_CONFIG_HOME/secrets-multi.zsh" out="$XDG_CACHE_HOME/out.zsh"
            print 'export PERSONAL="op-personal://Priv/A/f"' > "$tpl"
            print 'export AI="op-allenai://Work/C/f"' >> "$tpl"
            rm -f "$out"
            local err
            err=$(op_multi_inject -i "$tpl" -o "$out" 2>&1) \
                && { print "RESULT: FAIL (expected rc=1, got success)"; exit 1 }
            [[ "$err" == *allenai* ]] \
                || { print "RESULT: FAIL (error should name the signed-out account, got: $err)"; exit 1 }
            [[ ! -f "$out" ]] \
                || { print "RESULT: FAIL (out must not be written on failure)"; exit 1 }
            print "RESULT: PASS" ;;

        op-multi-rawref-no-default)
            # Raw op:// refs with no default-account directive → rejected.
            mkdir -p "${XDG_CONFIG_HOME}/secrets"
            local tpl2="$XDG_CONFIG_HOME/secrets-plain.zsh" out2="$XDG_CACHE_HOME/out2.zsh"
            print 'export X="op://Private/Item/f"' > "$tpl2"
            local err2
            err2=$(op_multi_inject -i "$tpl2" -o "$out2" 2>&1) \
                && { print "RESULT: FAIL (raw refs without default must be rejected)"; exit 1 }
            [[ "$err2" == *default-account* ]] \
                || { print "RESULT: FAIL (error should point at default-account, got: $err2)"; exit 1 }
            print "RESULT: PASS" ;;

        init-sa-default-nothing)
            # SA back-compat, nothing configured (no config dir, no template,
            # no cache): op_identity runs (missing cache → stale-gate fires),
            # goes inactive quietly, no token → inactive. The old front-of-
            # _op_init config check would have set the same final value.
            typeset -g OP_SERVICE_ACCOUNT_TOKEN=SENTINEL   # must stay unset-by-source
            export HOME="$(mktemp -d)"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            _ZDOT_OP_ACTIVE=9
            _op_init
            [[ "$_ZDOT_OP_ACTIVE" == 0 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 0)"; exit 1 }
            [[ "$OP_SERVICE_ACCOUNT_TOKEN" == SENTINEL ]] \
                || { print "RESULT: FAIL (no cache — token must not be sourced)"; exit 1 }
            grep -q 'service-account\|signin' "${FAKE_CALL_LOG}" \
                && { print "RESULT: FAIL (nothing configured — no SA/auth calls expected)"; exit 1 }
            print "RESULT: PASS" ;;

        init-sa-cached-token)
            # SA back-compat equivalence for the REMOVED front-of-_op_init
            # block: cached token present, template absent → no refresh, the
            # cache is sourced and its token drives _ZDOT_OP_ACTIVE=1 — same
            # final flag the old unconditional-zero + token-source flow gave.
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CACHE_HOME}/secrets"
            print 'export OP_SERVICE_ACCOUNT_TOKEN=sa-token-from-cache' \
                > "${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"
            _ZDOT_OP_ACTIVE=9
            _op_init
            [[ "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (_ZDOT_OP_ACTIVE=$_ZDOT_OP_ACTIVE expected 1)"; exit 1 }
            [[ "$OP_SERVICE_ACCOUNT_TOKEN" == sa-token-from-cache ]] \
                || { print "RESULT: FAIL (cached token not sourced, got '$OP_SERVICE_ACCOUNT_TOKEN')"; exit 1 }
            print "RESULT: PASS" ;;

        op-calls-carry-sudo-config)
            # Under sudo every op call must carry --config <real user's dir>,
            # including the public file helpers (regression: they ran bare).
            export SUDO_USER=someone REAL_HOME="$XDG_CONFIG_HOME/realhome"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            _op_logged_in personal
            op_upsert_file Vault item /dev/null > /dev/null 2>&1
            local want="--config $REAL_HOME/.config/op" line n=0
            while IFS= read -r line; do
                (( n++ ))
                [[ "$line" == "$want "* ]] \
                    || { print -r -- "RESULT: FAIL (op call without config: $line)"; exit 1 }
            done < "$FAKE_CALL_LOG"
            (( n >= 3 )) || { print "RESULT: FAIL (expected >=3 op calls, saw $n)"; exit 1 }
            print "RESULT: PASS" ;;

        headless-signin-evals-session)
            # The startup self-heal must eval what op signin prints (CLI-only
            # accounts print their session exports), not discard it.
            export FAKE_OP_MODE=recover FAKE_SIGNIN_EXPORT=1
            zstyle ':zdot:secrets:op' login-accounts personal
            zstyle ':zdot:secrets:op:personal' account-url my.1password.com
            unset OP_SESSION_fake
            _op_login_check \
                || { print "RESULT: FAIL (check rc=1, reply=${reply[*]})"; exit 1 }
            [[ "${OP_SESSION_fake:-}" == my.1password.com ]] \
                || { print "RESULT: FAIL (session export not eval-ed: '${OP_SESSION_fake:-}')"; exit 1 }
            print "RESULT: PASS" ;;

        init-inactive-sources-stale-cache)
            # Signed out at startup: the existing cache is still sourced, and
            # ONE warning names the cause and that the cache is stale.
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' profile ''
            zstyle ':zdot:secrets:op' login-accounts personal
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets"
            print 'export CACHED_SECRET=yes' > "${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            sleep 1
            print 'export CACHED_SECRET="op-personal://V/I/f"' > "${XDG_CONFIG_HOME}/secrets/secrets.zsh"
            local errf="$(mktemp)"
            _op_init 2> "$errf"
            [[ "${CACHED_SECRET:-}" == yes ]] \
                || { print "RESULT: FAIL (stale cache not sourced)"; exit 1 }
            local warns
            warns=$(grep -c 'secrets:' "$errf")
            [[ "$warns" == 1 ]] \
                || { print -r -- "RESULT: FAIL (expected 1 warning, got $warns: $(tr '\n' '|' < "$errf"))"; exit 1 }
            local frag
            for frag in 'not signed in to 1Password: personal' 'using cached secrets (older than the template)'; do
                grep -qF "$frag" "$errf" \
                    || { print -r -- "RESULT: FAIL (missing '$frag': $(tr '\n' '|' < "$errf"))"; exit 1 }
            done
            print "RESULT: PASS" ;;

        init-no-op-quiet-but-sources)
            # Opted-out machine (no_op): no warning, cache still sourced.
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' profile ''
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/op" "${XDG_CACHE_HOME}/secrets"
            : > "${XDG_CONFIG_HOME}/op/no_op"
            print 'export CACHED_SECRET=yes' > "${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            local errq="$(mktemp)"
            _op_init 2> "$errq"
            [[ "${CACHED_SECRET:-}" == yes ]] \
                || { print "RESULT: FAIL (cache not sourced on no_op machine)"; exit 1 }
            ! grep -q 'secrets:' "$errq" \
                || { print -r -- "RESULT: FAIL (no_op must stay quiet: $(tr '\n' '|' < "$errq"))"; exit 1 }
            print "RESULT: PASS" ;;

        inject-template-untagged-uses-default-account)
            # Untagged template + default-account configured: the inject must
            # name that account (regression: it ran a bare `op inject`, which
            # op rejects once two accounts are signed in). Same router the
            # mcp refresher uses.
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' default-account personal
            zstyle ':zdot:secrets:op:personal' account-url my.1password.com
            local tpl5="$XDG_CONFIG_HOME/mcp.json" out5="$XDG_CACHE_HOME/mcp.json"
            print '{"key": "op://API/Item/credential"}' > "$tpl5"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            op_inject_template "$tpl5" "$out5" \
                || { print "RESULT: FAIL (rc=$?; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            grep -q 'inject .*--account my.1password.com' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (inject did not name the account; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            [[ -s "$out5" ]] || { print "RESULT: FAIL (no output written)"; exit 1 }
            print "RESULT: PASS" ;;

        lazy-fresh-cache-no-op-calls)
            # Lazy + caches up to date: startup makes NO op calls (so no
            # Touch ID), marks op set up, and loads the cache.
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode lazy-login
            zstyle ':zdot:secrets:op' profile ''
            zstyle ':zdot:secrets:op' login-accounts personal
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            print 'export S="op-personal://V/I/f"' > "$tpl"
            sleep 1
            print 'export S=cached' > "$cache"
            _op_init 2>/dev/null
            [[ ! -s "$FAKE_CALL_LOG" ]] \
                || { print "RESULT: FAIL (op was called: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            [[ "$_ZDOT_OP_ACTIVE" == 1 && "$_ZDOT_OP_SESSION" == pending && "${S:-}" == cached ]] \
                || { print "RESULT: FAIL (active=$_ZDOT_OP_ACTIVE session=$_ZDOT_OP_SESSION S=${S:-})"; exit 1 }
            print "RESULT: PASS" ;;

        lazy-stale-template-checks-then-refreshes)
            # Lazy + template newer than cache: the refresh's first op call
            # runs the session check, then the inject proceeds.
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' mode lazy-login
            zstyle ':zdot:secrets:op' profile ''
            zstyle ':zdot:secrets:op' login-accounts personal
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            print 'export S=old' > "$cache"
            sleep 1
            print 'export S="op-personal://V/I/f"' > "$tpl"
            _op_init 2>/dev/null
            [[ "$_ZDOT_OP_SESSION" == ok && "${S:-}" == 'op://V/I/f' ]] \
                || { print "RESULT: FAIL (session=$_ZDOT_OP_SESSION S=${S:-}; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            local first
            first=$(head -1 "$FAKE_CALL_LOG")
            [[ "$first" == whoami* ]] \
                || { print "RESULT: FAIL (check should come first, got: $first)"; exit 1 }
            print "RESULT: PASS" ;;

        lazy-failed-check-no-reprompt)
            # Lazy + check fails: one warning, cache kept, and later op calls
            # are refused without calling op (no prompt per command).
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode lazy-login
            zstyle ':zdot:secrets:op' profile ''
            zstyle ':zdot:secrets:op' login-accounts personal
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            print 'export S=old' > "$cache"
            sleep 1
            print 'export S="op-personal://V/I/f"' > "$tpl"
            local errl="$(mktemp)"
            _op_init 2> "$errl"
            [[ "$_ZDOT_OP_SESSION" == failed && "${S:-}" == old ]] \
                || { print "RESULT: FAIL (session=$_ZDOT_OP_SESSION S=${S:-})"; exit 1 }
            local nwarn
            nwarn=$(grep -c 'not signed in to 1Password' "$errl")
            [[ "$nwarn" == 1 ]] \
                || { print -r -- "RESULT: FAIL (expected 1 warning, got $nwarn: $(tr '\n' '|' < "$errl"))"; exit 1 }
            local before after
            before=$(wc -l < "$FAKE_CALL_LOG")
            _op item get x 2>/dev/null && { print "RESULT: FAIL (_op should refuse)"; exit 1 }
            after=$(wc -l < "$FAKE_CALL_LOG")
            [[ "$before" == "$after" ]] \
                || { print "RESULT: FAIL (op called after failed check)"; exit 1 }
            print "RESULT: PASS" ;;

        lazy-op-refresh-recovers)
            # After a failed lazy check, op_identity re-checks and clears it.
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode lazy-login
            zstyle ':zdot:secrets:op' profile ''
            zstyle ':zdot:secrets:op' login-accounts personal
            export HOME="$(mktemp -d)"
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            print 'export S=cached' > "$cache"
            _op_init 2>/dev/null
            _op item get x 2>/dev/null
            [[ "$_ZDOT_OP_SESSION" == failed ]] \
                || { print "RESULT: FAIL (expected failed, got $_ZDOT_OP_SESSION)"; exit 1 }
            export FAKE_OP_MODE=success
            op_identity >/dev/null 2>&1 \
                || { print "RESULT: FAIL (op_identity rc=$?)"; exit 1 }
            [[ "$_ZDOT_OP_SESSION" == ok && "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print "RESULT: FAIL (session=$_ZDOT_OP_SESSION active=$_ZDOT_OP_ACTIVE)"; exit 1 }
            print "RESULT: PASS" ;;

        eager-refresh-reasks-interactive)
            # Eager login mode, signed out, a person runs refresh_shell_secrets
            # interactively: warn, sign in via op_auth, then refresh.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1 FAKE_SIGNIN_NEEDS_TTY=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' login-accounts personal
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets" "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local errr="$(mktemp)"
            print 'export S="op-personal://V/I/f"' > "$tpl"
            _ZDOT_OP_ACTIVE=0
            refresh_shell_secrets 2> "$errr" >/dev/null <<< "" \
                || { print -r -- "RESULT: FAIL (rc=$?; err: $(tr '\n' '|' < "$errr"))"; exit 1 }
            grep -q 'not signed in to 1Password: personal' "$errr" \
                || { print -r -- "RESULT: FAIL (no warning: $(tr '\n' '|' < "$errr"))"; exit 1 }
            [[ "${S:-}" == 'op://V/I/f' ]] \
                || { print "RESULT: FAIL (not refreshed, S=${S:-})"; exit 1 }
            print "RESULT: PASS" ;;

        eager-refresh-noninteractive-warns)
            # Same, but non-interactive (a script): warn with the hint, no op_auth.
            export FAKE_OP_MODE=fail
            zstyle ':zdot:secrets:op' mode login
            zstyle ':zdot:secrets:op' login-accounts personal
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets" "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local errr="$(mktemp)"
            print 'export S="op-personal://V/I/f"' > "$tpl"
            _ZDOT_OP_ACTIVE=0
            refresh_shell_secrets 2> "$errr" >/dev/null && { print "RESULT: FAIL (expected rc=1)"; exit 1 }
            grep -q 'not signed in to 1Password: personal; run op_identity' "$errr" \
                || { print -r -- "RESULT: FAIL (warning: $(tr '\n' '|' < "$errr"))"; exit 1 }
            ! grep -q 'Signing into' "$errr" \
                || { print "RESULT: FAIL (op_auth ran non-interactively)"; exit 1 }
            print "RESULT: PASS" ;;

        lazy-failed-interactive-reasks)
            # Lazy, earlier check failed; a person runs an op command
            # interactively: check again / re-ask instead of refusing.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' mode lazy-login
            zstyle ':zdot:secrets:op' login-accounts personal
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets" "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local errr="$(mktemp)"
            _ZDOT_OP_ACTIVE=0 _ZDOT_OP_SESSION=failed
            _op item get x 2>/dev/null
            [[ "$_ZDOT_OP_SESSION" == ok ]] \
                || { print "RESULT: FAIL (session=$_ZDOT_OP_SESSION; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            grep -q '^item get x' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (op never ran after re-ask)"; exit 1 }
            print "RESULT: PASS" ;;

        startup-never-reasks-interactive)
            # Interactive shell, lazy, check fails during STARTUP: warn with
            # the hint only — op_auth must not run inside _op_init.
            export FAKE_OP_MODE=fail FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' mode lazy-login
            zstyle ':zdot:secrets:op' login-accounts personal
            export HOME="$(mktemp -d)"
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets" "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local errr="$(mktemp)"
            print 'export S=old' > "$cache"
            sleep 1
            print 'export S="op-personal://V/I/f"' > "$tpl"
            _op_init 2> "$errr" >/dev/null
            ! grep -q 'Signing into\|— signing in' "$errr" \
                || { print -r -- "RESULT: FAIL (prompted during startup: $(tr '\n' '|' < "$errr"))"; exit 1 }
            grep -q 'run op_identity' "$errr" \
                || { print -r -- "RESULT: FAIL (no hint: $(tr '\n' '|' < "$errr"))"; exit 1 }
            print "RESULT: PASS" ;;

        sa-refresh-active-plain-inject)
            # Service-account mode, token loaded: refresh is a plain inject,
            # untouched by the login/lazy machinery.
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets" "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local errr="$(mktemp)"
            print 'export S="op://V/I/f"' > "$tpl"
            _ZDOT_OP_ACTIVE=1
            refresh_shell_secrets 2> "$errr" >/dev/null \
                || { print -r -- "RESULT: FAIL (rc=$?; err: $(tr '\n' '|' < "$errr"))"; exit 1 }
            grep -q '^inject --force --in-file' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (expected plain inject; log: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            ! grep -q 'whoami\|signin' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (SA mode ran sign-in calls)"; exit 1 }
            print "RESULT: PASS" ;;

        sa-refresh-inactive-warns-only)
            # Service-account mode, no token, interactive: warn, never prompt.
            export FAKE_OP_MODE=success FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/secrets" "${XDG_CACHE_HOME}/secrets" "${XDG_CONFIG_HOME}/op"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tpl="${XDG_CONFIG_HOME}/secrets/secrets.zsh" cache="${XDG_CACHE_HOME}/secrets/${USER}.secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local errr="$(mktemp)"
            print 'export S="op://V/I/f"' > "$tpl"
            _ZDOT_OP_ACTIVE=0
            refresh_shell_secrets 2> "$errr" >/dev/null && { print "RESULT: FAIL (expected rc=1)"; exit 1 }
            grep -q 'service-account token not loaded; run op_identity' "$errr" \
                || { print -r -- "RESULT: FAIL (warning: $(tr '\n' '|' < "$errr"))"; exit 1 }
            [[ ! -s "$FAKE_CALL_LOG" ]] \
                || { print "RESULT: FAIL (op was called: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            print "RESULT: PASS" ;;

        op-multi-two-pass-one-pipeline)
            # Two passes succeed through the single pipeline: one inject per
            # account, no loop re-run.
            export FAKE_OP_MODE=success
            local tp="$XDG_CONFIG_HOME/two.zsh" op2="$XDG_CACHE_HOME/two.zsh"
            print 'export A="op-personal://V/I/f"' > "$tp"
            print 'export B="op-allenai://W/I/f"' >> "$tp"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            op_multi_inject -i "$tp" -o "$op2" \
                || { print "RESULT: FAIL (rc=$?)"; exit 1 }
            local n
            n=$(grep -c '^inject' "$FAKE_CALL_LOG")
            [[ "$n" == 2 ]] \
                || { print "RESULT: FAIL (expected 2 injects, got $n: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            grep -q 'op://V/I/f' "$op2" && grep -q 'op://W/I/f' "$op2" \
                || { print "RESULT: FAIL (output: $(tr '\n' '|' < "$op2"))"; exit 1 }
            print "RESULT: PASS" ;;

        op-multi-loop-names-account)
            # Three passes (loop path); the middle one fails: named directly,
            # nothing written.
            export FAKE_OP_MODE=success FAKE_INJECT_FAIL_ACCOUNTS="beta"
            local t3="$XDG_CONFIG_HOME/three.zsh" o3="$XDG_CACHE_HOME/three.zsh"
            print 'export A="op-alpha://V/I/f"' > "$t3"
            print 'export B="op-beta://V/I/f"' >> "$t3"
            print 'export C="op-gamma://V/I/f"' >> "$t3"
            rm -f "$o3"
            local e3
            e3=$(op_multi_inject -i "$t3" -o "$o3" 2>&1) \
                && { print "RESULT: FAIL (expected failure)"; exit 1 }
            [[ "$e3" == *"pass 2 (account 'beta')"* ]] \
                || { print -r -- "RESULT: FAIL (message: $e3)"; exit 1 }
            [[ ! -f "$o3" ]] || { print "RESULT: FAIL (output written on failure)"; exit 1 }
            print "RESULT: PASS" ;;

        op-multi-helpers-removed)
            # The per-call helpers are gone after a successful AND a failed call.
            export FAKE_OP_MODE=success
            local th="$XDG_CONFIG_HOME/h.zsh" oh="$XDG_CACHE_HOME/h.zsh" f
            print 'export A="op-personal://V/I/f"' > "$th"
            op_multi_inject -i "$th" -o "$oh" || { print "RESULT: FAIL (success path rc=$?)"; exit 1 }
            for f in _op_multi_inject_input _op_multi_inject_pass _op_multi_inject_loop; do
                (( ${+functions[$f]} )) && { print "RESULT: FAIL ($f left after success)"; exit 1 }
            done
            export FAKE_INJECT_FAIL_ACCOUNTS=personal
            op_multi_inject -i "$th" -o "$oh" 2>/dev/null && { print "RESULT: FAIL (expected failure)"; exit 1 }
            for f in _op_multi_inject_input _op_multi_inject_pass _op_multi_inject_loop; do
                (( ${+functions[$f]} )) && { print "RESULT: FAIL ($f left after failure)"; exit 1 }
            done
            print "RESULT: PASS" ;;

        op-auth-sa-uses-token)
            # Service-account mode, token exported: op_auth just uses it —
            # no person sign-in.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/op" "${XDG_CACHE_HOME}/secrets"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tcache="${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local aout
            export OP_SERVICE_ACCOUNT_TOKEN=sa-token
            aout=$(op_auth 2>&1) \
                || { print -r -- "RESULT: FAIL (rc=$?; out=$aout)"; exit 1 }
            [[ "$aout" == *"using the service-account token"* ]] \
                || { print -r -- "RESULT: FAIL (message: $aout)"; exit 1 }
            ! grep -q '^signin' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (signed a person in)"; exit 1 }
            print "RESULT: PASS" ;;

        op-auth-sa-token-from-cache)
            # Token not in this shell but in the cache: loaded and used.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/op" "${XDG_CACHE_HOME}/secrets"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tcache="${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local aout
            unset OP_SERVICE_ACCOUNT_TOKEN
            print 'export OP_SERVICE_ACCOUNT_TOKEN=cached-token' > "$tcache"
            op_auth >/dev/null 2>&1 \
                || { print "RESULT: FAIL (rc=$?)"; exit 1 }
            [[ "${OP_SERVICE_ACCOUNT_TOKEN:-}" == cached-token ]] \
                || { print "RESULT: FAIL (token not loaded: '${OP_SERVICE_ACCOUNT_TOKEN:-}')"; exit 1 }
            print "RESULT: PASS" ;;

        op-auth-sa-no-token-errors)
            # No token anywhere: error pointing at op_identity, no sign-in,
            # no service-account setup.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/op" "${XDG_CACHE_HOME}/secrets"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tcache="${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local aout
            unset OP_SERVICE_ACCOUNT_TOKEN
            aout=$(op_auth 2>&1) && { print "RESULT: FAIL (expected rc=1)"; exit 1 }
            [[ "$aout" == *"run op_identity"* ]] \
                || { print -r -- "RESULT: FAIL (message: $aout)"; exit 1 }
            [[ ! -s "$FAKE_CALL_LOG" ]] \
                || { print "RESULT: FAIL (op called: $(tr '\n' '|' < "$FAKE_CALL_LOG"))"; exit 1 }
            print "RESULT: PASS" ;;

        op-auth-sa-reset-errors)
            # --reset in SA mode: caches dropped, accounts forgotten, token
            # gone, then the op_identity hint — the token is not re-used.
            export FAKE_OP_MODE=recover FAKE_INTERACTIVE=1
            _ZDOT_IS_INTERACTIVE=1
            zstyle ':zdot:secrets:op' profile ''
            mkdir -p "${XDG_CONFIG_HOME}/op" "${XDG_CACHE_HOME}/secrets"
            : > "${XDG_CONFIG_HOME}/op/config"
            local tcache="${XDG_CACHE_HOME}/secrets/${USER}.op-secrets.zsh"
            FAKE_CALL_LOG="$(mktemp)"; export FAKE_CALL_LOG
            local aout
            export OP_SERVICE_ACCOUNT_TOKEN=sa-token
            print 'export OP_SERVICE_ACCOUNT_TOKEN=sa-token' > "$tcache"
            aout=$(op_auth --reset 2>&1) && { print "RESULT: FAIL (expected rc=1)"; exit 1 }
            [[ "$aout" == *"run op_identity"* && ! -f "$tcache" ]] \
                || { print -r -- "RESULT: FAIL (out=$aout; cache left: $([[ -f $tcache ]] && echo yes))"; exit 1 }
            grep -q 'account forget --all' "$FAKE_CALL_LOG" \
                || { print "RESULT: FAIL (no forget)"; exit 1 }
            print "RESULT: PASS" ;;

        lazy-login-mode)
            zstyle ':zdot:secrets:op' mode lazy-login
            _op_get_mode && [[ "$REPLY" == lazy-login ]] \
                || { print "RESULT: FAIL (mode '$REPLY')"; exit 1 }
            _op_is_login || { print "RESULT: FAIL (_op_is_login false)"; exit 1 }
            print "RESULT: PASS" ;;

        op-refresh-alias)
            # The old name still works: prints the new name, then does the job.
            export FAKE_OP_MODE=success
            zstyle ':zdot:secrets:op' mode login
            local rerr="$(mktemp)" rout
            op_refresh 2> "$rerr" >/dev/null || { print -r -- "RESULT: FAIL (rc=$?; $(<$rerr))"; exit 1 }
            rout=$(<"$rerr")
            [[ "$rout" == *"op_refresh is now op_identity"* && "$_ZDOT_OP_ACTIVE" == 1 ]] \
                || { print -r -- "RESULT: FAIL (out=$rout active=$_ZDOT_OP_ACTIVE)"; exit 1 }
            print "RESULT: PASS" ;;

        *) print "RESULT: FAIL (unknown case $2)"; exit 2 ;;
    esac
    exit 0
fi

typeset -a cases=(default-mode login-mode unknown-mode-falls-back empty-mode-falls-back \
    whoami-success-noninteractive whoami-fail-noninteractive whoami-fail-interactive-recovers \
    no-op-sentinel op-refresh-login-dispatch op-refresh-feedback \
    init-login-passive-fail init-login-passive-ok \
    init-sa-default-nothing init-sa-cached-token \
    login-accounts-partial-in login-accounts-none-in init-login-multi op-auth-walks-all \
    login-check-heals-every-account op-auth-resolves-account-url \
    op-multi-pipe-mode op-multi-explicit-order op-multi-fallback-names-account \
    account-url-map op-multi-signedout-error op-multi-rawref-no-default op-auth-reset \
    op-calls-carry-sudo-config headless-signin-evals-session \
    init-inactive-sources-stale-cache init-no-op-quiet-but-sources \
    inject-template-untagged-uses-default-account \
    lazy-fresh-cache-no-op-calls lazy-stale-template-checks-then-refreshes \
    lazy-failed-check-no-reprompt lazy-op-refresh-recovers \
    eager-refresh-reasks-interactive eager-refresh-noninteractive-warns \
    lazy-failed-interactive-reasks startup-never-reasks-interactive \
    sa-refresh-active-plain-inject sa-refresh-inactive-warns-only \
    op-multi-two-pass-one-pipeline op-multi-loop-names-account \
    op-multi-helpers-removed op-auth-sa-uses-token op-auth-sa-token-from-cache \
    op-auth-sa-no-token-errors op-auth-sa-reset-errors lazy-login-mode \
    op-refresh-alias)
typeset -i fails=0
for c in $cases; do
    out="$(zsh -f "${(%):-%x}" --case "$c" 2>&1 | grep '^RESULT:')"
    printf '%-32s %s\n' "$c" "$out"
    [[ "$out" == *PASS* ]] || (( fails++ ))
done
print ""
if (( fails )); then print "OVERALL: FAIL ($fails)"; exit 1; fi
print "OVERALL: PASS"
exit 0
