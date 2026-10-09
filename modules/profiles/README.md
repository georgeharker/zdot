# lib/profiles — Machine Profile Module

Declares "which profile variant is this setup" as a generic, consumer-agnostic
concept (a machine persona) and exports it as `ZDOT_PROFILE` for both shells
and child processes. The module is deliberately opinionless about what varies
by profile — consumers decide. Built-in consumers today:

- `secrets`: selects which 1Password secrets template set gets injected
  (`secrets-<profile>.zsh`) when `':zdot:secrets:op' profile` is unset
  (the generic name is the backstop; a secrets-specific zstyle still wins).
- Per-machine env mappings (e.g. `~/.config/zdot-modules/env` exporting
  `MINUET_BACKEND` for the editor's AI completion backend).

## Configuration

All configuration is zstyle-driven, read at hook time. Set values from a
`profile-configure` group hook — not from a consumer:

```zsh
_my_profile_configure() {
    zstyle ':zdot:profile' name work
}
zdot_register_hook _my_profile_configure interactive noninteractive \
    --group profile-configure
```

| zstyle key | Type | Default | Purpose |
|---|---|---|---|
| `':zdot:profile' name` | string | *(empty)* | Profile name. Unset/empty = no profile. |
| `:zdot:profile` `allowed-names` | array | *(unset)* | Optional list of valid names; a configured name outside the list warns. |

## Semantics

- **Zstyle-only resolution**: `ZDOT_PROFILE` is an output, never read back.
- **Always exported**: once the hook has run, `ZDOT_PROFILE` is set — an
  *empty* value means "explicitly no profile". Consumers can distinguish that
  from "the profiles module did not run" (variable unset) via
  `[[ -n "${ZDOT_PROFILE+x}" ]]`.
- **Accessor**: `zdot_profile_get` leaves the resolved name in `$REPLY`
  (empty string when none) for call-time reads.
- **Provided phase**: `profiles-configured`. Depend on it
  (`--requires profiles-configured`) rather than guessing load order.