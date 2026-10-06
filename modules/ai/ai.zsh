#!/usr/bin/env zsh
# ai: OpenAI-compatible LLM integration for zsh (wraps the zsh-ai plugin)
#
# Loads the standalone zsh-ai plugin as a zdot module. Four keybind-driven
# zle widgets share one async backbone:
#
#   ^Xa  ask       multi-line scratchpad -> N candidate commands -> accept
#   ^Xm  modify    rewrite the current BUFFER per an instruction -> accept
#   ^Xq  question  freeform Q&A, answer rendered below the prompt
#   ^Xi  FIM       fill-in-the-middle completion at the cursor
#
# Talks to any OpenAI-compatible HTTP endpoint (llama.cpp --server, ollama,
# LM Studio, vLLM, OpenRouter, ...). Bringing the model up is out of scope —
# this module only points the plugin at one you've already started.
#
# ── Configuration ────────────────────────────────────────────────────────────
# Everything is a zstyle, and every default this module sets is a *backstop*
# (applied only when you haven't set the value yourself). All of it is
# therefore overridable from any of three equivalent places:
#
#   (a) directly in .zshrc, before `zdot_load_module ai`
#   (b) a hook in the `ai-configure` group (DAG-time, runs before _ai_configure)
#   (c) a `zdot_before_module ai` callback (parse-time, before this file runs)
#
# The zsh-ai plugin itself is the georgeharker/zsh-ai repo, declared with
# zdot_use_plugin (cloned/updated by the plugin system) and sourced from
# _ai_load via zdot_load_plugin like any other plugin.
#
# Two phases (zdot_define_module): _ai_configure consumes the ai-configure
# group, so it runs after user override hooks and seeds backstop zstyle
# defaults; _ai_load then ensures the plugin's Python venv exists, adds the CLI
# to PATH, and sources the plugin (which reads those zstyles at source time).
#
# The plugin ships a Python bridge (its own pyproject.toml). _ai_load runs
# `ai-sync` in the plugin dir to create its `.venv` when missing or stale —
# hence the dependency on the uv module (uv-configured). The sync runs with
# VIRTUAL_ENV unset so it builds the plugin's own venv, not whatever venv is
# active. Note the bridge's base deps (polyllmkit[bridge,md]) do NOT install
# the SDK adapters' SDKs (claude_code, anthropic, google — polyllmkit's base
# extras are empty by design, unlike pre-split llmkit 0.1.0). ai-sync's
# no-arg path therefore seeds sync-extras on by default (see the knob
# below); a machine can narrow or empty the list, and whatever's set
# persists across self-heal syncs.
#
# Module knobs (`:zdot:ai` namespace):
#   add-cli-to-path  boolean; prepend <plugin>/bin to $PATH for the `zsh-ai`
#                      CLI (default off)
#   api-key-env      shortcut: forwarded to `:zsh-ai:* api_key_env` when that
#                      upstream value isn't already set
#   sync-extras      extra names forwarded as `--extra <name>` to ai-sync's
#                      default (no-arg) invocation, via zdot_zstyle_get's
#                      seed-if-unset. Default: `claude anthropic google` —
#                      all SDK adapters work out of the box, as the old
#                      monolithic llmkit implied. Override the whole list
#                      per machine (e.g. just `claude` when the TOML only
#                      maps claude); an explicitly empty value disables
#                      extras. A widget mapped to an SDK adapter without its
#                      extra fails at call time with "the claude_code adapter
#                      needs the Claude Agent SDK". Manual
#                      `ai-sync <uv-args...>` is forwarded verbatim (extras
#                      never auto-added there); a later plain sync
#                      re-seeds/re-reads the list, so it persists.
#
# Commands:
#   ai-sync [uv-sync-args...]  (re)sync the plugin's Python venv. _ai_load only
#                      bootstraps the venv on first run (when .venv is missing);
#                      this re-syncs an existing one too. With no args it
#                      forwards `--no-dev --extra <name>...` from the
#                      sync-extras knob (default: claude anthropic google,
#                      so the SDK adapters work out of the box); with args it
#                      forwards them verbatim (a later plain sync re-applies
#                      the list — see the knob above).
#
# Plugin knobs this module seeds as backstop defaults:
#   :zsh-ai:*        endpoint           http://localhost:11434/v1
#   :zsh-ai:scratch  enabled            yes
#   :zsh-ai:scratch  keybind            ^Xa
#   :zsh-ai:scratch  modify_keybind     ^Xm
#   :zsh-ai:scratch  question_keybind   ^Xq
#   :zsh-ai:fim      enabled            yes
#   :zsh-ai:fim      keybind            ^Xi
#
# Everything else (model, max_tokens, temperature, candidates, show_thinking,
# stream_question, FIM templates/stop_tokens, per-feature endpoint/api_key
# overrides, custom `headers`, ...) falls through to the plugin's own defaults —
# set them in an `ai-configure` hook. No `model` is seeded: until you set one the
# plugin prompts you to. See the upstream lib/config.zsh for the full namespace
# map.
#
# The zstyle axis stays fully supported — with no TOML models file the widget
# config resolves entirely from these zstyles. Machines that carry their whole
# provider config in the plugin's TOML models file (adapter/model/endpoint/key/
# tuning in [providers.*], widget→provider wiring in [profiles.*]; parsed to a
# session cache on first use) need only pick a profile section per host — see
# the example hook below. Per field TOML wins: provider → [defaults] → zstyle.
#
# Custom request headers: the `headers` zstyle (array of KEY=VALUE) and/or a
# TOML provider's `headers` — e.g. the `x-opencode-request` key OpenCode Zen's
# qwen pool requires (503 failover_exhausted without it). Semantics (HTTP
# adapters only, value expansion) live upstream: see the plugin's
# lib/config.zsh and `zsh-ai-llm chat --help`.
#
# Example override hook (drop in .zshrc or your own module) — the profile
# pattern, all provider config in the plugin's TOML models file:
#
#   _my_ai_configure() {
#       # Pick a [profiles.*] section of ~/.config/zsh-ai/models.toml (the
#       # widget→provider map; providers themselves live in the TOML too):
#       zstyle ':zsh-ai:*' profile my-machine
#       # Display/tuning knobs that aren't provider fields stay zstyle-side:
#       zstyle ':zsh-ai:scratch' stream_question yes
#   }
#   zdot_register_hook _my_ai_configure interactive --group ai-configure
#
# Or the pure-zstyle pattern (no models file, single backend):
#
#   _my_ai_configure() {
#       zstyle ':zsh-ai:*'       endpoint    'http://localhost:11435/v1'
#       zstyle ':zsh-ai:*'       api_key_env 'LLAMA_API_KEY'
#       zstyle ':zsh-ai:scratch' model       'Qwen3.6-35B-A3B-Q4'
#       zstyle ':zsh-ai:fim'     model       'Qwen3.6-35B-A3B-Q4'
#       # This pattern has no models.toml, so no TOML provider is present to
#       # carry headers — this zstyle is then the only mechanism. Only needed
#       # when hitting OpenCode Zen (its qwen pool 503s without it):
#       zstyle ':zsh-ai:*'       headers     'x-opencode-request=zsh-ai-${uuid}'
#   }
#   zdot_register_hook _my_ai_configure interactive --group ai-configure

# Consumer of the ai-configure group: runs after any user override hooks, so
# user values win and these backstops fill only what's unset. The plugin reads
# these zstyles at source time, so they must land before _ai_load runs.
_ai_configure() {
    zdot_zstyle_default ':zsh-ai:*'       endpoint         'http://localhost:11434/v1'

    zdot_zstyle_default ':zsh-ai:scratch' enabled          yes
    zdot_zstyle_default ':zsh-ai:scratch' keybind          '^Xa'    # ask
    zdot_zstyle_default ':zsh-ai:scratch' modify_keybind   '^Xm'    # modify BUFFER
    zdot_zstyle_default ':zsh-ai:scratch' question_keybind '^Xq'    # freeform Q&A

    zdot_zstyle_default ':zsh-ai:fim'     enabled          yes
    zdot_zstyle_default ':zsh-ai:fim'     keybind          '^Xi'

    # api-key-env shortcut: forward `:zdot:ai api-key-env` to the upstream
    # `:zsh-ai:* api_key_env` only when the upstream value isn't already set.
    local _ake _existing
    if zstyle -s ':zdot:ai' api-key-env _ake \
        && ! zstyle -s ':zsh-ai:*' api_key_env _existing; then
        zstyle ':zsh-ai:*' api_key_env "$_ake"
    fi
}

# Runs after _ai_configure: ensure the plugin's Python venv exists, optionally
# put the CLI on PATH, then source the plugin. zstyles are fully resolved by
# now, so widget registration sees them.
_ai_load() {
    local _ai_path
    zdot_plugin_path georgeharker/zsh-ai
    _ai_path="$REPLY"

    # The plugin ships a Python bridge (pyproject.toml; bin/zsh-ai-llm execs
    # .venv/bin/python). Build/refresh that venv with uv when it's missing OR
    # stale. VIRTUAL_ENV is unset for the sync so uv builds the plugin's own
    # .venv rather than whatever venv is active (the uv module activates ~/.venv).
    #
    # Self-heal: ai-sync stamps .venv/.ai-sync-stamp on success; we re-sync when
    # the plugin's pyproject.toml — or the vendored llmkit submodule's
    # pyproject.toml — is newer than that stamp. That picks up dependency changes
    # on update (e.g. the llmkit extraction adding a dep) without a manual
    # ai-sync. A pre-stamp venv (older install, no stamp file) self-heals too:
    # zsh's `-nt` is false when the stamp is missing, so we test for it
    # explicitly rather than relying on the comparison.
    if [[ -f "${_ai_path}/pyproject.toml" ]]; then
        local _ai_stamp="${_ai_path}/.venv/.ai-sync-stamp"
        if [[ ! -d "${_ai_path}/.venv" \
              || ! -f "$_ai_stamp" \
              || "${_ai_path}/pyproject.toml" -nt "$_ai_stamp" \
              || "${_ai_path}/external/llmkit/pyproject.toml" -nt "$_ai_stamp" ]]; then
            # ai-sync's default (no args) is `uv sync --no-dev` plus the
            # :zdot:ai sync-extras knob — SDK adapter extras (claude etc.)
            # persist across self-heal syncs that way, since uv's `sync` makes
            # extras an exact set.
            ai-sync || zdot_warn "ai: the zsh-ai LLM bridge may not work without its venv"
        fi
    fi

    # Optional CLI on PATH (zsh-ai ships bin/zsh-ai). Explicit `export` so PATH
    # is re-exported regardless of the path<->PATH tie's export attribute.
    if zstyle -t ':zdot:ai' add-cli-to-path; then
        export PATH="${_ai_path}/bin:$PATH"
    fi

    zdot_load_plugin georgeharker/zsh-ai
}

# (Re)sync the zsh-ai plugin's Python venv with uv. _ai_load bootstraps the
# venv only when it's missing/stale; this command re-syncs an existing one too,
# so you can change what's installed after the fact. Args are forwarded
# verbatim to `uv sync`; with none it applies the default flag set (--no-dev)
# plus every name from the sync-extras knob (see the comment above the module
# knob — default claude/anthropic/google, seeded-on-read via zdot_zstyle_get,
# so SDK adapters work out of the box). (uv's `sync` treats extras as an
# exact set: a plain sync strips any extra that isn't named, which is why the knob rides on the no-arg path.)
# VIRTUAL_ENV is unset so uv targets the plugin's own .venv, not an active one
# (the uv module activates ~/.venv).
ai-sync() {
    local _ai_path
    zdot_plugin_path georgeharker/zsh-ai
    _ai_path="$REPLY"
    if [[ ! -f "${_ai_path}/pyproject.toml" ]]; then
        zdot_warn "ai: no pyproject.toml under ${_ai_path}; is the plugin cloned?"
        return 1
    fi
    local -a args=("$@")
    if (( ! $# )); then
        # Seed-if-unset + read in one call (zdot_zstyle_get — presence via
        # zstyle -g, so even an explicit blank value counts as "already set").
        # Default: every SDK adapter, so a models.toml mapping a widget to
        # claude_code/anthropic/google works without per-machine wiring. A
        # machine overrides the whole list (e.g. just `claude`) or sets an
        # explicit empty value to opt out; either suppresses the default.
        args=(--no-dev)
        local -a _ai_extras
        zdot_zstyle_get -a ':zdot:ai' sync-extras _ai_extras claude anthropic google
        local _ai_e
        for _ai_e in "${_ai_extras[@]}"; do
            # Empty elements (explicit opt-out) collapse to "no extras".
            [[ -n "$_ai_e" ]] && args+=(--extra "$_ai_e")
        done
    fi
    zdot_info "ai: syncing zsh-ai venv (uv sync ${args[*]})…"
    if ( unset VIRTUAL_ENV; builtin cd "$_ai_path" && uv sync "${args[@]}" ); then
        # Stamp the venv so _ai_load's self-heal check knows it's in sync with
        # the current pyproject(s). A dedicated marker (not the .venv dir mtime)
        # stays stable across uv's own writes.
        command touch "${_ai_path}/.venv/.ai-sync-stamp" 2>/dev/null
    else
        zdot_warn "ai: uv sync failed"
        return 1
    fi
}

# Declare the plugin so the zdot plugin system clones/updates it. It is *loaded*
# later, from _ai_load, so ai-configure hooks (and _ai_configure) can set
# zstyles before zsh-ai registers its widgets (which reads zstyle at source time).
zdot_use_plugin georgeharker/zsh-ai

# zsh-ai is fundamentally interactive (zle widgets) — interactive context only.
# --auto-configure-group makes _ai_configure the consumer of the ai-configure
# user-extension group. The load phase requires:
#   plugins-cloned   georgeharker/zsh-ai is on disk before _ai_load sources it
#   secrets-loaded   API key (e.g. sourced from 1Password) is available
#   uv-configured    uv is on PATH so _ai_load can create the plugin's .venv
zdot_define_module ai \
    --configure _ai_configure \
    --load _ai_load \
    --auto-configure-group \
    --context interactive \
    --requires plugins-cloned secrets-loaded uv-configured
