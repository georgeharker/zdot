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
# `uv sync` in the plugin dir to create its `.venv` when missing — hence the
# dependency on the uv module (uv-configured). The sync runs with VIRTUAL_ENV
# unset so it builds the plugin's own venv, not whatever venv is active. It
# always adds the plugin's `claude` extra (Claude Agent SDK) when present, so
# the `provider = claude_code` backend works without a manual reinstall.
#
# Module knobs (`:zdot:ai` namespace):
#   add-cli-to-path  boolean; prepend <plugin>/bin to $PATH for the `zsh-ai`
#                      CLI (default off)
#   api-key-env      shortcut: forwarded to `:zsh-ai:* api_key_env` when that
#                      upstream value isn't already set
#
# Commands:
#   ai-sync [uv-sync-args...]  (re)sync the plugin's Python venv. _ai_load only
#                      bootstraps the venv on first run (when .venv is missing);
#                      this re-syncs an existing one too. Run it to add an extra
#                      after the fact — e.g. `ai-sync --extra claude` to enable
#                      the claude_code backend on a venv built without it. With
#                      no args it forwards the same flags _ai_load uses.
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
# overrides, ...) falls through to the plugin's own defaults — set them in an
# `ai-configure` hook. No `model` is seeded: until you set one the plugin
# prompts you to. See the upstream lib/config.zsh for the full namespace map.
#
# Example override hook (drop in .zshrc or your own module):
#
#   _my_ai_configure() {
#       zstyle ':zsh-ai:*'       endpoint    'http://localhost:11435/v1'
#       zstyle ':zsh-ai:*'       api_key_env 'LLAMA_API_KEY'
#       zstyle ':zsh-ai:scratch' model       'Qwen3.6-35B-A3B-Q4'
#       zstyle ':zsh-ai:fim'     model       'Qwen3.6-35B-A3B-Q4'
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
    # .venv/bin/python). Create that venv with uv when it's missing. VIRTUAL_ENV
    # is unset for the sync so uv builds the plugin's own .venv rather than
    # syncing into whatever venv is active (the uv module activates ~/.venv).
    if [[ -f "${_ai_path}/pyproject.toml" && ! -d "${_ai_path}/.venv" ]]; then
        # First run: build the venv. ai-sync's defaults include the optional
        # `claude` extra (Claude Agent SDK), so the claude_code provider works
        # out of the box. Re-run `ai-sync` by hand to change extras later.
        ai-sync || zdot_warn "ai: the zsh-ai LLM bridge may not work without its venv"
    fi

    # Optional CLI on PATH (zsh-ai ships bin/zsh-ai). Explicit `export` so PATH
    # is re-exported regardless of the path<->PATH tie's export attribute.
    if zstyle -t ':zdot:ai' add-cli-to-path; then
        export PATH="${_ai_path}/bin:$PATH"
    fi

    zdot_load_plugin georgeharker/zsh-ai
}

# (Re)sync the zsh-ai plugin's Python venv with uv. _ai_load bootstraps the
# venv only when it's missing; this command re-syncs an existing one too, so you
# can change what's installed after the fact — most usefully adding an optional
# extra: `ai-sync --extra claude` enables the claude_code chat backend on a venv
# that was built without it. Args are forwarded verbatim to `uv sync`; with none
# it uses the same flags the first-run bootstrap does (--no-dev --extra claude).
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
    (( $# )) || args=(--no-dev --extra claude)
    zdot_info "ai: syncing zsh-ai venv (uv sync ${args[*]})…"
    ( unset VIRTUAL_ENV; builtin cd "$_ai_path" && uv sync "${args[@]}" ) \
        || { zdot_warn "ai: uv sync failed"; return 1; }
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
