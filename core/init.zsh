#!/usr/bin/env zsh
# core/init: Initialization orchestration
# Ties together plugin cloning, bundle init, group resolution, plan execution,
# and bytecode compilation into a single zdot_init entry point.

# ============================================================================
# Initialization
# ============================================================================

# Clone all plugin repos synchronously and mark the plugins-cloned phase.
_zdot_init_clone() {
    zdot_plugins_clone_all
}
zdot_register_hook _zdot_init_clone interactive noninteractive \
    --name plugins-cloned-init \
    --provides plugins-cloned
typeset -g _ZDOT_INIT_CLONE_HOOK_ID=$REPLY

# Run each bundle's init function (registered via zdot_register_bundle --init).
_zdot_init_bundles() {
    local _bundle_name
    for _bundle_name in "${_ZDOT_BUNDLE_HANDLERS[@]}"; do
        local _init_fn="${_ZDOT_BUNDLE_INIT_FN[$_bundle_name]:-}"
        if [[ -n $_init_fn ]] && (( ${+functions[$_init_fn]} )); then
            "$_init_fn"
        fi
    done
}

# Build the execution plan (cache-aware), fire all hooks, then compile to bytecode.
_zdot_init_plan_and_execute() {
    if ! load_cache; then
        zdot_build_execution_plan
        zdot_cache_save_plan
    fi
    zdot_execute_all

    # Compile all modules to bytecode for faster loading.
    # Must run after zdot_execute_all: plugin execution may generate new .zsh
    # files on disk (init scripts, lazy loaders, etc.) that don't exist until
    # sourcing completes. Compiling first would miss those files.
    zdot_cache_compile_all
}

# Single entry point: clone → bundle init → group resolution → plan → execute → compile.
zdot_init() {
    (( _ZDOT_INIT_DONE )) && return 0
    typeset -g _ZDOT_INIT_DONE=1
    _zdot_execute_hook "$_ZDOT_INIT_CLONE_HOOK_ID" "_zdot_init_clone"
    _zdot_init_bundles
    _zdot_init_resolve_groups
    _zdot_init_plan_and_execute
}
