#!/usr/bin/env zsh
# completions: Shell completion management system
# Executes registered file-based and live completions

# Autoload module functions immediately
zdot_module_autoload_funcs

# Module initialization - Phase 1: Setup fpath and register file completions
_completions_init() {
    # Add completion directories to fpath
    local completions_dir=$(zdot_get_completions_dir)

    # Add global completions directory to fpath
    if [[ -d "$completions_dir" ]]; then
        fpath=("$completions_dir" $fpath)
    fi

    # Add per-module completion directories to fpath.
    # Uses the loaded-module map so user-path modules are included alongside lib/ modules.
    local _mod _mod_dir
    for _mod in "${(k)_ZDOT_MODULE_SOURCE_DIR}"; do
        _mod_dir="${_ZDOT_MODULE_SOURCE_DIR[$_mod]}"
        local comp_dir="${_mod_dir}/completions"
        if [[ -d "$comp_dir" ]]; then
            fpath=("$comp_dir" $fpath)
        fi
    done
    
    # Register standard file-based completions
    zdot_register_completion_file "gh" "gh completion -s zsh"
    zdot_register_completion_file "tailscale" "tailscale completion zsh"
    zdot_register_completion_file "sharedserver" "sharedserver completion zsh"
}

# Phase 2: Run live completions and refresh stale file completions after tools are available
_completions_finalize() {
    refresh_completions

    for func in "${_ZDOT_COMPLETION_LIVE[@]}"; do
        if typeset -f "$func" > /dev/null; then
            "$func"
        else
            zdot_error "completions: live function '${func}' not found"
        fi
    done
}

# Register hooks
# Phase 1: Early fpath setup (before compinit).
# Exposes the `completions-configure` group so users / downstream modules can
# register completion contributions before fpath is finalised:
#   zdot_register_hook _my_completions interactive --group completions-configure
zdot_register_hook _completions_init interactive \
    --requires bootstrap-ready \
    --requires-group completions-configure \
    --provides completions-paths-ready

# Phase 2: Late live completions (after tools available)
#
# Member of the `completions` group: any hook that PRODUCES completion files or
# adds to fpath should join this group (--group completions). The deferred
# compinit-activate hook gates on --requires-group completions, so it runs only
# after every producer has drained (full fpath) — but NOT behind unrelated slow
# deferred hooks (e.g. nvm), which simply aren't members. Distinct from the
# `completions-configure` group above, which gates pre-fpath contributions.
#
# `completions-producers` group: any hook that calls a completion registration
# function (zdot_register_completion_file / zdot_register_completion_live) from
# INSIDE its body must join this group with `--group completions-producers`, so
# that refresh_completions (below) sees the registration before it generates
# files, AND the tool the gen command invokes is on PATH. Top-level (module-
# source-time) registrations don't need it — they always precede this hook — but
# joining is still correct if the gen command needs a tool the hook puts on PATH
# (e.g. uv). Skipped optional members (a tool-gated hook on a machine without the
# tool) are dropped from the barrier, so the group is safe for optional producers.
# autocomplete-post-configured is provided ONLY by the optional `autocompletion`
# module. A base `completions` module must not HARD-require an optional sibling:
# a standalone config that loads `completions` without `autocompletion` would
# fail to build a plan at all ("no hook provides autocomplete-post-configured").
# Use --requires-optional: when autocompletion is loaded this is a full
# dependency — finalize is force-deferred behind it (a deferred phase) and
# ordered after its plugins, so compinit (gated --requires-group completions)
# still lands after them, exactly as before; when autocompletion is absent the
# edge is silently dropped and finalize simply runs without it.
zdot_register_hook _completions_finalize interactive \
    --group completions \
    --requires completions-paths-ready \
    --requires-optional autocomplete-post-configured \
    --requires-group completions-producers \
    --provides completions-ready

# Phase 3: compinit — the single launch point for the completion system.
#
# Owned by THIS module (not autocompletion): compinit is a completion-system
# primitive, so a user who doesn't load the autocompletion module must still get
# it. Gated --requires-group completions, so it runs after every producer in the
# `completions` group (members join with --group completions; see the group as
# the composition seam). compinit runs directly in the deferred drain —
# zdot_compinit_run is idempotent and does not hang in the zsh-defer/ZLE context.
_completions_compinit() { zdot_compinit_run; }

zdot_register_hook _completions_compinit interactive \
    --deferred \
    --requires-group completions \
    --provides compinit-done
