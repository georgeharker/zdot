# ai — OpenAI-compatible LLM integration

Loads the standalone [zsh-ai](https://github.com/) plugin as a zdot module,
giving you four keybind-driven `zle` widgets that share one async backbone:

| Keybind | Widget | What it does |
|---|---|---|
| `^Xa` | ask | multi-line scratchpad → N candidate commands → accept |
| `^Xm` | modify | rewrite the current `BUFFER` per an instruction → accept |
| `^Xq` | question | freeform Q&A, answer rendered below the prompt |
| `^Xi` | FIM | fill-in-the-middle completion at the cursor |

The plugin talks to any OpenAI-compatible HTTP endpoint (llama.cpp `--server`,
ollama, LM Studio, vLLM, OpenRouter, …). Running the model is out of scope —
this module only points the plugin at one you've already started.

## Requirements

- A checkout of the `zsh-ai` plugin. By default the module looks in
  `~/Development/zsh/zsh-ai`; override with `zstyle ':zdot:ai' path …`.
- A reachable OpenAI-compatible endpoint (default `http://localhost:11434/v1`).
- Interactive shell — the module registers `zle` widgets and is skipped in
  noninteractive contexts.

## What it does

1. Resolves the plugin path and, if `add-cli-to-path` is set, prepends
   `<path>/bin` to `$PATH`.
2. Seeds a small set of **backstop** defaults (see below) — each is applied
   only if you haven't set it yourself.
3. Forwards the `api-key-env` shortcut to the plugin's `api_key_env` style.
4. Sources `zsh-ai.plugin.zsh`, which registers the widgets.

## Configuration

Every value is a zstyle, and every default this module sets is a backstop, so
all of it is overridable. The cleanest place is an `ai-configure` group hook
(see below); you can also set styles directly in `.zshrc` before
`zdot_load_module ai`.

### Module knobs — `:zdot:ai`

| zstyle | Default | Purpose |
|---|---|---|
| `path` | `~/Development/zsh/zsh-ai` | Location of the zsh-ai checkout |
| `add-cli-to-path` | off | Prepend `<path>/bin` to `$PATH` (for the `zsh-ai` CLI) |
| `api-key-env` | — | Name of the env var holding the API key; forwarded to `:zsh-ai:* api_key_env` unless that's already set |

### Plugin knobs seeded as backstop defaults

| zstyle | Default |
|---|---|
| `:zsh-ai:* endpoint` | `http://localhost:11434/v1` |
| `:zsh-ai:scratch enabled` | `yes` |
| `:zsh-ai:scratch keybind` | `^Xa` |
| `:zsh-ai:scratch modify_keybind` | `^Xm` |
| `:zsh-ai:scratch question_keybind` | `^Xq` |
| `:zsh-ai:fim enabled` | `yes` |
| `:zsh-ai:fim keybind` | `^Xi` |

No `model` is seeded — until you set one the plugin prompts you to. Everything
else (`max_tokens`, `temperature`, `candidates`, `show_thinking`,
`stream_question`, FIM `template_*`/`stop_tokens`, per-feature
`endpoint`/`api_key` overrides, …) falls through to the plugin's own defaults.
See the upstream `lib/config.zsh` for the full namespace map.

## Extension point — `ai-configure` group

A hook group named `ai-configure` runs before `_ai_init`. Register a hook into
it to set any `:zsh-ai:*` or `:zdot:ai` zstyle before the module reads them and
sources the plugin:

```zsh
_my_ai_configure() {
    zstyle ':zsh-ai:*'       endpoint    'http://localhost:11435/v1'
    zstyle ':zsh-ai:*'       api_key_env 'LLAMA_API_KEY'
    zstyle ':zsh-ai:scratch' model       'Qwen3.6-35B-A3B-Q4'
    zstyle ':zsh-ai:scratch' max_tokens  4096   # room for reasoning models
    zstyle ':zsh-ai:fim'     model       'Qwen3.6-35B-A3B-Q4'
    # Qwen-Coder FIM tokens
    zstyle ':zsh-ai:fim'     template_prefix '<|fim_prefix|>'
    zstyle ':zsh-ai:fim'     template_suffix '<|fim_suffix|>'
    zstyle ':zsh-ai:fim'     template_middle '<|fim_middle|>'
    zstyle ':zsh-ai:fim'     stop_tokens '<|fim_pad|>' '<|endoftext|>' '<|im_end|>'
}

zdot_register_hook _my_ai_configure interactive --group ai-configure
```

Because the module's defaults are backstops, values you set here win — the
module won't overwrite them.

## Provides

- Phase: `ai-ready`

## Notes

- The module lists `secrets-loaded` as an optional require. If you load the
  `secrets` module (e.g. an API key from 1Password), `ai` waits for it; if you
  don't, the require silently drops and `ai` loads anyway.
- Widget registration reads zstyle at plugin source time, which is why the
  module sources the plugin inside its DAG-time hook — after `ai-configure`
  hooks have run.
