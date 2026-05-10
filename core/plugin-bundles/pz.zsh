#!/usr/bin/env zsh
# core/plugin-bundles/pz.zsh: Prezto plugin bundle handler
# Provides:
#   - Prezto repo cloning (at file-source time)
#   - ZPREZTODIR setup
#   - .zpreztorc stub (if absent) — prevents Prezto from auto-loading modules
#   - Prezto init.zsh sourcing (in plugins-cloned hook)
#   - pz: spec support for zdot_use_plugin pz:modules/<name>

# ============================================================================
# Early Setup: Clone Prezto if enabled
# ============================================================================

local _zdot_pz_enabled
zstyle -b ':zdot:plugins' pz _zdot_pz_enabled

if [[ "$_zdot_pz_enabled" == yes ]]; then
    # Ensure cache dir is initialized before resolver calls touch it
    _zdot_plugins_init

    # Set ZPREZTODIR early — Prezto's own init.zsh and the .zpreztorc stub
    # both expect this variable to point at the Prezto checkout root.
    zdot_plugin_path sorin-ionescu/prezto
    typeset -g ZPREZTODIR=$REPLY

    # Clone Prezto (--recurse-submodules handled by zdot_plugin_clone)
    zdot_plugin_clone sorin-ionescu/prezto
fi

# ============================================================================
# Bundle Handler Functions
# ============================================================================

# Match: returns 0 if this handler owns the spec
zdot_bundle_pz_match() {
    [[ $1 == pz:* ]]
}

# Repo and URL resolution: every pz:* spec is backed by a single Prezto
# checkout. Delegate to the public plugin resolvers so the cache path and
# GitHub URL conventions stay in one place.
zdot_bundle_pz_repo() {
    zdot_plugin_path sorin-ionescu/prezto
}

zdot_bundle_pz_url() {
    zdot_plugin_url sorin-ionescu/prezto
}

# Path: filesystem path for a pz: spec.
#   pz:modules/git -> <repo>/modules/git
zdot_bundle_pz_path() {
    local relpath=${1#pz:}
    zdot_bundle_pz_repo
    REPLY="$REPLY/$relpath"
}

# Clone: no-op — Prezto is cloned at file-source time above.
# Populate _ZDOT_PLUGINS_PATH so the core fast-path sentinel can find it.
zdot_bundle_pz_clone() {
    local spec=$1
    zdot_bundle_pz_path "$spec"
    _ZDOT_PLUGINS_PATH[$spec]=$REPLY
    return 0
}

# Load: call pmodload for the module name extracted from the spec
# pz:modules/git -> pmodload git
zdot_bundle_pz_load() {
    local spec=$1
    # Only handles pz:modules/* specs
    if [[ $spec == pz:modules/* ]]; then
        local module_name="${spec#pz:modules/}"
        pmodload "$module_name"
    fi
    return 0
}

# ============================================================================
# Bundle Init
# ============================================================================

zdot_bundle_pz_init() {
    # Step 1: environment / state setup (nothing extra needed; ZPREZTODIR is
    # set at file-source time so that zdot_plugin_clone can reference it early)

    # Step 2: register the Prezto init hook
    zdot_register_hook _zdot_pz_load_init interactive noninteractive \
        --requires plugins-cloned \
        --provides pz-bundle-initialized \
        --provides pz-init-loaded \
        --requires-group pz-configure
}

# ============================================================================
# Plugin Bundle API
# ============================================================================

# Register this bundle handler with the registry — only when enabled
if [[ "$_zdot_pz_enabled" == yes ]]; then
    zdot_register_bundle pz --init-fn zdot_bundle_pz_init
    zdot_use_bundle sorin-ionescu/prezto
fi

# ============================================================================
# Helpers
# ============================================================================

# Convenience wrapper: declare a Prezto module for loading
zdot_use_pz() {
    local module=$1
    zdot_use_plugin "pz:modules/${module}"
}

# ============================================================================
# Hook: Source Prezto init.zsh after plugins-cloned
# Provides pz-init-loaded milestone so downstream hooks can depend on it.
# ============================================================================

_zdot_pz_load_init() {
    [[ "$_zdot_pz_enabled" == yes ]] || return 0

    # Create a minimal .zpreztorc stub if none exists.
    # Prezto's init.zsh unconditionally sources ${ZDOTDIR:-$HOME}/.zpreztorc.
    # The stub sets pmodules to empty so Prezto does not auto-load anything —
    # zdot handles module loading via zdot_use_plugin pz:modules/<name>.
    local zpreztorc="${ZDOTDIR:-${HOME}}/.zpreztorc"
    if [[ ! -f "$zpreztorc" ]]; then
        {
            print "# .zpreztorc — auto-generated stub by zdot pz bundle"
            print "# zdot loads Prezto modules via zdot_use_plugin pz:modules/<name>."
            print "# Leave pmodules empty to prevent Prezto from auto-loading."
            print "zstyle ':prezto:load' pmodules"
        } >| "$zpreztorc"
    fi

    # Source Prezto's init.zsh to register pmodload and read .zpreztorc
    if [[ -f "${ZPREZTODIR}/init.zsh" ]]; then
        source "${ZPREZTODIR}/init.zsh"
    else
        zdot_warn "pz bundle: Prezto not found at ${ZPREZTODIR}"
    fi
}

