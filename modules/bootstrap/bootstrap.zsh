#!/usr/bin/env zsh
# bootstrap: initial per-machine setup phase
# Foundation module - provides the bootstrap-ready phase
#
# This module owns the "initial setup" milestone that sits just above xdg.
# It does no work of its own; it is the coordinator that closes the
# `bootstrap` group and exposes `bootstrap-ready` once every member has run.
#
#   - Group: bootstrap
#       Register early per-machine setup hooks here and they are guaranteed to
#       run (after xdg-configured) before bootstrap-ready is provided:
#           zdot_register_hook _my_setup interactive --group bootstrap
#       local_rc's local_env is a member of this group (see local_rc.zsh).
#
#   - Phase: bootstrap-ready
#       Depend on this from any module that needs per-machine environment in
#       place before it runs:
#           zdot_register_hook _my_init interactive --requires bootstrap-ready

# Coordinator function - no work of its own; the registration below is what
# gates the phase behind the group.
_bootstrap_init() {
    zdot_verbose "bootstrap: per-machine setup complete"
}

# Registered directly (not via zdot_simple_hook): a coordinator overrides every
# convention zdot_simple_hook would derive (provides, requires, contexts), so an
# explicit zdot_register_hook — naming the hook and linking its function — is
# clearer than fighting the sugar.
#
# Requires ONLY the bootstrap group and provides bootstrap-ready. xdg is itself a
# member of the group (see modules/xdg), so --requires-group bootstrap already
# waits for xdg-configured — no need to name it here. bootstrap-ready therefore
# transitively guarantees xdg-configured, and nothing special-cases xdg.
zdot_register_hook _bootstrap_init interactive noninteractive \
    --requires-group bootstrap \
    --provides bootstrap-ready
