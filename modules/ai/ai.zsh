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
#   (b) a hook in the `ai-configure` group (DAG-time, runs before _ai_init)
#   (c) a `zdot_before_module ai` callback (parse-time, before this file runs)
#
# The zsh-ai plugin itself is the georgeharker/zsh-ai repo, declared with
# zdot_use_plugin (cloned/updated by the plugin system) and sourced from
# _ai_init via zdot_load_plugin like any other plugin.
#
# Module knobs (`:zdot:ai` namespace):
#   add-cli-to-path  boolean; prepend <plugin>/bin to $PATH for the `zsh-ai`
#                      CLI (default off)
#   api-key-env      shortcut: forwarded to `:zsh-ai:* api_key_env` when that
#                      upstream value isn't already set
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

_ai_init() {
    # Optional CLI on PATH (zsh-ai ships bin/zsh-ai). Use an explicit `export`
    # so PATH is re-exported to child processes regardless of whether the
    # path<->PATH tie carries the export attribute in this shell.
    if zstyle -t ':zdot:ai' add-cli-to-path; then
        local _ai_path
        zdot_plugin_path georgeharker/zsh-ai
        _ai_path="$REPLY"
        export PATH="${_ai_path}/bin:$PATH"
    fi

    # ── Backstop defaults (all overridable via the ai-configure group) ────────
    # zdot_zstyle_default seeds each value only when the user hasn't set it. A
    # hook in the ai-configure group runs before _ai_init, so any user value
    # present at this point wins and the default is skipped.
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

    # Load the plugin. Widget registration reads zstyle at source time, which is
    # why this runs inside the DAG-time hook — after any ai-configure group
    # hooks have had their chance to set zstyles.
    zdot_load_plugin georgeharker/zsh-ai
}

# Declare the plugin so the zdot plugin system clones/updates it. It is *loaded*
# later, from _ai_init, so ai-configure hooks can set zstyles before zsh-ai
# registers its widgets (which reads zstyle at source time).
zdot_use_plugin georgeharker/zsh-ai

# zsh-ai is fundamentally interactive (zle widgets) — interactive context only.
#
# plugins-cloned ensures georgeharker/zsh-ai is on disk before _ai_init loads it.
#
# secrets-loaded is listed as a require + --optional so the hook waits for the
# secrets module when it's loaded (e.g. an API key sourced from 1Password) but
# is silently skipped when nothing provides that phase. If your key comes from
# elsewhere and you don't load secrets, this still works — the optional require
# simply drops.
zdot_simple_hook ai \
    --requires xdg-configured secrets-loaded plugins-cloned \
    --optional \
    --provides ai-ready \
    --context interactive \
    --requires-group ai-configure
