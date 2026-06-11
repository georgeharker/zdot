#!/usr/bin/env zsh
# core/compinit.zsh: Shared compinit machinery (bundle-agnostic)
#
# Provides:
#   - Compdef queue (queue compdef calls before compinit runs)
#   - zdot_compinit_run: single idempotent entry point (deferred launch from
#     the completions module; `finally`-group fallback in core)
#   - Pluggable compdump path and refresh-check hooks
#
# Bundle-specific concerns (OMZ compdump metadata, SHORT_HOST, etc.) live in
# their respective plugin-bundles/*.zsh files, not here.

# ============================================================================
# Boolean helper
# ============================================================================
#
# zdot_is_true VAR_NAME
#   Returns 0 (true) when the *value* of the named variable is one of:
#   1, y, yes, t, true, on  (case-insensitive).
#   Returns 1 (false) otherwise, including when the variable is unset or empty.
#
# Usage:
#   ZDOT_SKIP_COMPAUDIT=yes
#   zdot_is_true ZDOT_SKIP_COMPAUDIT && echo "skip"

zdot_is_true() {
    local val="${(P)1}"
    [[ "${val:l}" == (1|y|yes|t|true|on) ]]
}

# ============================================================================
# Compaudit insecure-directory warning
# ============================================================================
#
# zdot_handle_completion_insecurities: called after compinit -i when there are
# insecure directories on fpath.  Prints a warning with remediation advice.
# Mirrors OMZ's handle_completion_insecurities, using the [zdot] prefix.
#
# Called in the background (&|) so it never blocks the prompt.

zdot_handle_completion_insecurities() {
    autoload -Uz compaudit
    local -a insecure_dirs
    insecure_dirs=(${(f)"$(compaudit 2>/dev/null)"})
    [[ ${#insecure_dirs[@]} -eq 0 ]] && return 0

    print >&2 "[zdot] Insecure completion-related directories found:"
    print -l >&2 "  ${^insecure_dirs}"
    print >&2 ""
    print >&2 "  To fix, run:  compaudit | xargs chmod g-w,o-w"
    print >&2 ""
    print >&2 "  Or skip the audit entirely by setting one of:"
    print >&2 "    ZDOT_SKIP_COMPAUDIT=true"
    print >&2 "    zstyle ':zdot:compinit' skip-compaudit true"
}

# ============================================================================
# Compdef Queue
# ============================================================================
#
# OMZ plugins (and others) call `compdef` at source time, before compinit has
# run.  We install a stub that queues those calls and replays them after
# compinit finishes.

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

# compdef stub: installed immediately so bare `compdef` calls from plugins
# are intercepted before compinit runs.
#
# Behaviour:
#   - non-interactive shell  → no-op (completions not needed; suppresses errors)
#   - interactive, pre-compinit → queue for replay after compinit
#   - after compinit → this function is removed by zdot_compdef_queue_process;
#     the real compdef function (defined by compinit) handles calls from that
#     point on
compdef() {
    zdot_interactive || return 0
    _compdef_queue "$@"
}

zdot_compdef_queue_process() {
    # The stub was already removed before compinit ran (in zdot_compinit_run).
    # compinit defines the real compdef; if for any reason it's still missing,
    # bail silently rather than erroring out.
    if ! (( ${+functions[compdef]} )); then
        return 0
    fi

    local cmd
    for cmd in "$_ZDOT_COMPDEF_QUEUE[@]"; do
        compdef "${(z)cmd}"
    done

    _ZDOT_COMPDEF_QUEUE=()
}

# ============================================================================
# Pluggable compdump helpers
# ============================================================================
#
# _zdot_compdump_path: returns the path to the compdump file.
# Bundle handlers may override this function after sourcing this file.
#
# _zdot_compdump_needs_refresh: returns 0 (true) when a full compinit is
# needed, 1 (false) when the cached dump is still valid.
# Bundle handlers may override this function after sourcing this file.

_zdot_compdump_path() {
    print "${ZDOTDIR:-${HOME}}/.zcompdump${SHORT_HOST:+-${SHORT_HOST}}-${ZSH_VERSION}"
}

# ============================================================================
# Compdump Metadata and Refresh
# ============================================================================

typeset -g _ZDOT_COMPDUMP_META_FILE

zdot_compdump_meta_init() {
    [[ -n "$_ZDOT_COMPDUMP_META_FILE" ]] && return 0
    local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/zdot"
    [[ ! -d "$cache_dir" ]] && mkdir -p "$cache_dir"
    _ZDOT_COMPDUMP_META_FILE="${cache_dir}/zcompdump-metadata.zsh"
}

# Ensure the generic completions cache dir exists and is on fpath.
# Uses _zdot_completions_dir() (defined in core/core.zsh) — bundle-agnostic.
# Called at source time so the dir is ready before compinit runs.
{
    _zdot_completions_dir
    local _zdot_comp_dir="$REPLY"
    [[ -d "$_zdot_comp_dir" ]] || mkdir -p "$_zdot_comp_dir"
    (( ${fpath[(Ie)"$_zdot_comp_dir"]} )) || fpath=("$_zdot_comp_dir" $fpath)
}

_zdot_fpath_files() {
    local d
    for d in $fpath; do
        [[ -d "$d" ]] && print -l "$d"/_*(N) 2>/dev/null
    done | sort
}

_zdot_compdump_age_expired() {
    local compfile="$(_zdot_compdump_path)"
    local max_age_hours=${1:-24}
    [[ ! -f "$compfile" ]] && return 0
    local age_seconds=$(($(date +%s) - $(stat -f %m "$compfile" 2>/dev/null || stat -c %Y "$compfile" 2>/dev/null)))
    local age_hours=$((age_seconds / 3600))
    [[ $age_hours -ge $max_age_hours ]]
}

# Bundle-specific stamp: default returns empty string.
# Override in plugin-bundles/*.zsh to return a bundle-specific revision string
# (e.g. git rev-parse HEAD of the bundle's repo).
_zdot_compdump_bundle_stamp() {
    print ""
}

_zdot_compdump_needs_refresh() {
    local compfile="$(_zdot_compdump_path)"
    [[ ! -f "$compfile" ]] && return 0
    [[ -n "$_ZDOT_FORCE_COMPDUMP_REFRESH" ]] && return 0

    zdot_compdump_meta_init

    local current_stamp current_fpath current_fpath_files
    current_stamp=$(_zdot_compdump_bundle_stamp)
    current_fpath=($fpath)
    current_fpath_files=$(_zdot_fpath_files)

    typeset -g  ZSH_COMPDUMP_STAMP
    typeset -ga ZSH_COMPDUMP_FPATH
    typeset -g  ZSH_COMPDUMP_FPATH_FILES
    [[ -r "$_ZDOT_COMPDUMP_META_FILE" ]] && source "$_ZDOT_COMPDUMP_META_FILE"

    if [[ "$current_stamp"        != "$ZSH_COMPDUMP_STAMP"       ]] ||
       [[ "$current_fpath"        != "$ZSH_COMPDUMP_FPATH"       ]] ||
       [[ "$current_fpath_files"  != "$ZSH_COMPDUMP_FPATH_FILES" ]]; then
        return 0
    fi
    return 1
}

zdot_compdump_write_meta() {
    zdot_compdump_meta_init
    typeset -g  ZSH_COMPDUMP_STAMP
    typeset -ga ZSH_COMPDUMP_FPATH
    typeset -g  ZSH_COMPDUMP_FPATH_FILES
    ZSH_COMPDUMP_STAMP=$(_zdot_compdump_bundle_stamp)
    ZSH_COMPDUMP_FPATH=($fpath)
    ZSH_COMPDUMP_FPATH_FILES=$(_zdot_fpath_files)
    { typeset -p ZSH_COMPDUMP_STAMP
      typeset -p ZSH_COMPDUMP_FPATH
      typeset -p ZSH_COMPDUMP_FPATH_FILES } >| "$_ZDOT_COMPDUMP_META_FILE"
}

zdot_compdump_recompile() {
    local compfile="$(_zdot_compdump_path)"
    {
        if [[ -s "$compfile" && (! -s "${compfile}.zwc" || "$compfile:A" -nt "${compfile}.zwc:A") ]]; then
            if command mkdir "${compfile}.lock" 2>/dev/null; then
                autoload -U zrecompile
                zrecompile -q -p "$compfile"
                command rm -rf "${compfile}.zwc.old" "${compfile}.lock" 2>/dev/null
            fi
        fi
    } &!
}

zdot_compinit_post_full() {
    zdot_compdump_write_meta
    zdot_compdump_recompile
}

# ============================================================================
# Compinit Run
# ============================================================================
#
# zdot_compinit_run is the single entry point for running compinit. It is
# invoked once, from the completions module's deferred launch hook
# (_completions_compinit), which is gated --requires-group completions so it
# fires only after every completion producer has drained and $fpath is complete.
#
# It runs directly in the deferred (zsh-defer/ZLE) context. The historical
# concern that compinit hangs there does not reproduce on current zsh (verified):
# the fpath scan completes synchronously. Running it directly — rather than via a
# flag + precmd relay — keeps the whole compinit lifecycle in one place and makes
# completion live at the first prompt. It is idempotent (guarded by
# _ZDOT_COMPINIT_DONE).
#
# Fast path: when the compdump is fresh (_zdot_compdump_needs_refresh returns
#   false) we call compinit -C to load cached completions without regenerating
#   the dump.
# Full path: when a refresh is needed we call compinit -i/-u.  Bundle handlers
#   that want to write metadata or recompile in the background should hook
#   zdot_compinit_post_full (called after full compinit, before queue replay).
#
# After compinit finishes, zdot_compdef_queue_process replays any compdef
# calls that were queued by the stub before compinit ran.

typeset -g _ZDOT_COMPINIT_DONE

zdot_compinit_run() {
    # Completions are not needed in non-interactive shells.
    zdot_interactive || return 0

    # Guard against double-invocation (idempotent).
    [[ -n "$_ZDOT_COMPINIT_DONE" ]] && return 0

    _zdot_compdef_queue_init

    autoload -Uz compinit

    local compfile="$(_zdot_compdump_path)"

    local do_full_compinit=1
    if [[ -f "$compfile" ]] && ! _zdot_compdump_needs_refresh; then
        do_full_compinit=0
    fi

    # Remove our stub BEFORE calling compinit so compinit can freely define the
    # real compdef function.  If the stub is present when compinit runs, compinit
    # silently skips redefining compdef (a function with that name already
    # exists), leaving us with no real compdef after the stub is removed.
    unfunction compdef 2>/dev/null

    if [[ $do_full_compinit -eq 1 ]]; then
        # Determine whether to skip compaudit.
        #
        # Priority (highest → lowest):
        #   1. zstyle ':zdot:compinit' skip-compaudit   (true/yes/1/false/no/0)
        #   2. ZDOT_SKIP_COMPAUDIT env var              (true/yes/1/… via zdot_is_true)
        #   3. ZSH_DISABLE_COMPFIX (deprecated OMZ var) — honoured for compat
        #
        # When skip is true  → compinit -u (trust all dirs, skip audit)
        # When skip is false → compinit -i (ignore insecure dirs) + warn
        local _zdot_skip_audit=0
        if zstyle -t ':zdot:compinit' skip-compaudit; then
            _zdot_skip_audit=1
        elif zdot_is_true ZDOT_SKIP_COMPAUDIT; then
            _zdot_skip_audit=1
        elif [[ -n "${ZSH_DISABLE_COMPFIX+x}" ]]; then
            # Deprecated: ZSH_DISABLE_COMPFIX (OMZ convention).
            # Any non-empty value other than explicit "false"/"no"/"0" means skip.
            if zdot_is_true ZSH_DISABLE_COMPFIX \
               || [[ "$ZSH_DISABLE_COMPFIX" == true ]]; then
                _zdot_skip_audit=1
            fi
        fi

        if [[ $_zdot_skip_audit -eq 1 ]]; then
            compinit -u -d "$compfile"
        else
            autoload -Uz compaudit
            compinit -i -d "$compfile"
            zdot_handle_completion_insecurities &|
        fi

        # Run post-full-compinit work (write metadata, background recompile).
        zdot_compinit_post_full
    else
        # Fast path: compdump is fresh.  compinit -C loads cached completions
        # and defines the real compdef function without regenerating the dump.
        compinit -C -d "$compfile"
    fi

    _ZDOT_COMPINIT_DONE=1
    zdot_compdef_queue_process
}

# ============================================================================
# Compinit fallback — the floor (finally group)
# ============================================================================
#
# Belt-and-braces: guarantees compinit runs even when no module drives it — e.g.
# a config without the completions module, whose _completions_compinit is the
# PRIMARY launch. Registered into the `finally` group, so it runs at the very end
# of the deferred drain — after every producer, $fpath fully populated, still
# within first-prompt idle. Idempotent (no-op if the primary already ran), and a
# one-shot (finally fires once, so nothing to deregister).
#
# `finally` is the right dependency point: it means "after the drain has
# drained", and it deliberately does NOT fire when a hook genuinely stalls — so a
# real misconfiguration still surfaces as a stall error rather than being
# silently papered over here. Lives in core so compinit depends on no module.
_zdot_compinit_fallback() {
    [[ -n "$_ZDOT_COMPINIT_DONE" ]] && return 0
    zdot_compinit_run
}

zdot_register_hook _zdot_compinit_fallback interactive --group finally
