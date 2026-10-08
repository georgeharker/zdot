#!/usr/bin/env zsh
# profiles: machine-profile resolution and the ZDOT_PROFILE environment
# variable
#
# Declares "which profile variant is this setup" as a first-class, generic
# concept (a machine persona) and exports it as ZDOT_PROFILE for both shells
# and child processes (e.g. nvim reads vim.env.ZDOT_PROFILE). The module is
# deliberately opinionless about WHAT varies by profile — consumers (the
# secrets module's 1Password template selection, per-machine env mappings like
# MINUET_BACKEND, ...) each decide.
#
# ── Resolution ───────────────────────────────────────────────────────────────
# Zstyle-only: ZDOT_PROFILE is an output of this module, never read back.
#
#   zstyle ':zdot:profile' name <string>     profile name; unset = no profile
#   zstyle ':zdot:profile' allowed-names     optional array of valid names;
#                                            unknown configured names warn
#
# Set the zstyle from a `profile-configure` group hook (see below) in .zshrc
# or a machine module — not from a consumer.
#
# ── The "none" case ──────────────────────────────────────────────────────────
# ZDOT_PROFILE is ALWAYS set once this module's hook has run: an EMPTY value
# means "explicitly no profile", so consumers can distinguish that from "the
# profiles module did not run at all" (variable unset):
#
#   # profiles module ran: none vs set —
#   if [[ -n "${ZDOT_PROFILE+x}" ]]; then ... fi   # ran
#   [[ -n "$ZDOT_PROFILE" ]]                       # profile configured
#
# ── Lifecycle ────────────────────────────────────────────────────────────────
# zdot_simple_hook provides (name)-configured = profiles-configured after
# bootstrap-ready and the profile-configure group. Requires bootstrap-ready +
# group profile-configure; interactive + noninteractive (default), so child
# processes from `zsh -c` one-shots see ZDOT_PROFILE too.
#
# Consumers should depend on the profiles-configured phase; a convenience
# accessor (zdot_profile_get) is also available for call-time reads:
#
#   zdot_profile_get          # REPLY = profile name ('' when none)

# Resolve the configured profile from the ':zdot:profile' name zstyle.
# Empty REPLY means "explicitly no profile configured".
# Usage: zdot_profile_get; local profile="$REPLY"
zdot_profile_get() {
    zstyle -s ':zdot:profile' name REPLY || REPLY=""
}

# Validate the resolved profile against the optional allowed-names list.
_profiles_validate() {
    zdot_profile_get
    [[ -n "$REPLY" ]] || return 0
    local -a allowed
    if zstyle -a ':zdot:profile' allowed-names allowed; then
        local _n
        for _n in "${allowed[@]}"; do
            [[ "$REPLY" == "$_n" ]] && return 0
        done
        zdot_warn "profiles: profile '${REPLY}' is not in :zdot:profile allowed-names (${allowed[*]})"
    fi
}

# Module initialization: resolve and export ZDOT_PROFILE (always set —
# empty when no profile), so the secrets module's template selection,
# per-machine env mappings and other consumers see a single value.
_profiles_init() {
    zdot_profile_get
    export ZDOT_PROFILE="$REPLY"
    _profiles_validate
}

# Export + provide the profiles-configured phase, gated on machine hooks in
# the profile-configure group (set the zstyle there, not in consumers).
zdot_simple_hook profiles \
    --requires-group profile-configure \
    --provides profiles-configured