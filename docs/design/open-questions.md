# Open Questions

Live, unresolved items distilled from retired design docs (2026-06-10).
When one is resolved, either delete its entry or grow it into a design doc /
decision record.

## Batch plugin declaration ergonomics

*(from the retired `api-improvements.md` brainstorm)*

Goal: a trivial migration path for users with a monolithic
`plugins=( ... )` section — replace it with one zdot call instead of N
`zdot_use_plugin` lines. Open design choices:

- Extend `zdot_define_module` to accept a plugin *set*, or add a dedicated
  function that better expresses intent?
- `zdot_import_antidote` already covers the antidote file format; the open
  case is inline declaration ergonomics.

## Module genericity: residue and the examples/ question

*(remaining items from the retired `module-improvements.md` audit)*

The genericity work largely shipped: secrets/fzf/shell-extras/nodejs/venv/
dotfiler are zstyle-parameterized, the big personal env exports
(`DEFAULT_USER`, `DEVDIR`, …) are gone, and aliases/mcp left the tree. Two
leftovers:

- **`env` still carries personal preferences** — `ZOXIDE_CMD_OVERRIDE=cz`
  and `BAT_THEME="tokyonight_night"` (`modules/env/env.zsh`). Either
  zstyle-parameterize them or accept env as personal-flavored and say so in
  its catalog entry.
- **The `examples/` directory never materialized** — annotated
  personal-flavored modules (aliases, mcp, machine-specific env) as
  starting points for users. Decide whether the
  [Module Writer's Guide](../module-guide.md) examples make this redundant.

## `ssh -G` hang inside process substitution (fix identified, not applied)

*(condensed from the retired `ssh-issue.md` debugging transcript)*

**Mechanism — confirmed**: `ssh -G <host>` hangs when run inside a process
substitution `<(...)` unless stdin is explicitly redirected:

```zsh
< <(command ssh -G host 2>/dev/null)             # HANGS
< <(command ssh -G host </dev/null 2>/dev/null)  # works
command ssh -G host 2>/dev/null | cat            # works (pipes fine)
echo $(command ssh -G host 2>/dev/null)          # works (cmd-subst fine)
```

Inside `<(...)` ssh inherits a stdin that blocks (neither the terminal nor
`/dev/null`); `</dev/null` makes it exit immediately. **Not
Ghostty-specific** — reproduces in Terminal.app; it surfaces via Ghostty's
`ssh()` shell-integration wrapper because that wrapper reads
`<(command ssh -G "$@")` when `GHOSTTY_SHELL_FEATURES` includes
`ssh-terminfo`.

**Ruled out** (tested): the malformed `Match Exec` block in `~/.ssh/config`
(real, but separate — see remaining work), `SSH_AUTH_SOCK`/1Password agent,
the zdot refactor (old commit also hangs), the `ssh` function definition
itself, stderr redirection, ProxyCommand/ForwardAgent/AddKeysToAgent.

**Identified fix, never applied**: override Ghostty's `ssh()` (defined in
its `shell-integration/zsh/ghostty-integration`, ~line 280) with an
identical function adding `</dev/null` to the `ssh -G` line — as a local
override in zdot config (don't patch Ghostty; updates overwrite it). The
override must load *after* Ghostty's integration; load-ordering was never
verified. (The transcript names the pre-extraction path
`lib/ssh/ssh.zsh`; today this would be a user module or shell-extras
adjunct.)

**Genuinely still open**: the final observation that blanking `~/.zshrc`
(subshell-only) made the hang disappear — implying some zdot-configured
state in the child's environment participates, which the stdin mechanism
alone doesn't explain. Unresolved tension; revisit if the `</dev/null`
override doesn't fully cure it. Secondary task: fix the `Match Exec`
syntax in `~/.ssh/config` (`test -S …/agent.sock && test -z
"${SSH_CONNECTION}"`).
