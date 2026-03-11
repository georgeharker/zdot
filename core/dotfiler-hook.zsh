# core/dotfiler-hook.zsh
# zdot update hook for the dotfiler hook system.
#
# Installed into the dotfiler hooks directory as a symlink pointing back here.
# %x resolves (via :A) to this file's real location inside ZDOT_REPO/core/,
# giving us ZDOT_REPO reliably without any stub or pre-set variable.
#
# Always sourced — never exec'd.
# Callers (dotfiler's update.zsh and check_update.zsh) source this file directly.
# All _zdot_update_hook_* functions are defined in-process.
# _zdot_update_hook_register registers phase functions into the caller's registry
# via _update_register_hook (defined by the caller — real in update.zsh, shim in
# check_update.zsh). No DOTFILER_HOOK_MODE or branching needed.

# Self-location: :A resolves the symlink to the real backing repo inside ZDOT_REPO/core/
# ZDOT_DIR (the linktree path) must NOT be clobbered here — core.zsh sets it correctly.
ZDOT_REPO="${${${(%):-%x}:A}:h:h}"

# For bootstrapping purposes
ZDOT_DIR="${ZDOT_DIR:-${ZDOT_REPO}}"

# ---------------------------------------------------------------------------
# Logging shims
# update-impl.zsh uses zdot_* logging functions natively (zdot's API).
# When sourced into dotfiler's process (check_update.zsh), zdot_* functions
# won't exist — define them mapped to dotfiler's equivalents, and set a flag
# so the cleanup knows to undefine them.
# Check all five — any missing means we need to define the full set.
# ---------------------------------------------------------------------------
typeset -g _zdot_hook_defined_log_shims=0
if (( ! $+functions[zdot_warn] || ! $+functions[zdot_info] || \
      ! $+functions[zdot_error] || ! $+functions[zdot_verbose] || \
      ! $+functions[zdot_log_debug] )); then
    _zdot_hook_defined_log_shims=1
    function zdot_warn()      { warn "$@"; }
    function zdot_info()      { info "$@"; }
    function zdot_error()     { error "$@"; }
    function zdot_verbose()   { verbose "$@"; }
    function zdot_log_debug() { log_debug "$@"; }
fi

# ---------------------------------------------------------------------------
# Locate dotfiler scripts directory
# update_core.zsh is guaranteed loaded by the dotfiler caller — no need to
# source it again.  We only need _zdot_dotfiler_scripts_dir for update-impl.zsh.
# Source update-impl.zsh first (needs update_core.zsh functions), then use its
# canonical _zdot_update_find_dotfiler_scripts to resolve the scripts path.
# ---------------------------------------------------------------------------
source "${ZDOT_DIR}/core/update-impl.zsh" || return 2

_zdot_update_find_dotfiler_scripts || {
    error "could not locate dotfiler scripts directory"
    return 2
}
_zdot_dotfiler_scripts_dir="$REPLY"

# ---------------------------------------------------------------------------
# Entry point — register phase functions into the caller's registry
# ---------------------------------------------------------------------------
_zdot_update_hook_register
