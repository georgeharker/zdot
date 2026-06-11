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

## examples/ directory for personal-module patterns

*(remaining item from the retired `module-improvements.md` audit)*

The genericity work shipped (zstyle-parameterized secrets/fzf/venv/etc.;
personal env vars removed; aliases/mcp no longer in the tree). What never
materialized is an `examples/` directory holding annotated personal-flavored
modules (aliases, mcp, machine-specific env) as starting points for users.
Decide whether the [Module Writer's Guide](../module-guide.md) examples make
this redundant.

## Ghostty: `ssh -G` hang inside process substitution

*(condensed from the retired `ssh-issue.md` debugging transcript)*

**Symptom**: `command ssh -G <host>` hangs when invoked from a process
substitution inside a zsh function — only under Ghostty; fine in other
terminals. Root cause unconfirmed; no code changes made.

**Ruled in/out so far**: the hang reproduces with `command ssh` (not the
wrapper alone); suspects examined without a verdict include the OMZ `ssh`
plugin (via shell-extras), fast-syntax-highlighting, `omz:lib`, zsh-abbr,
and the 1Password agent / `Match Exec` block in `~/.ssh/config`.

**Next steps (require a live Ghostty session)**:

1. `echo $TERM $SSH_AUTH_SOCK $GHOSTTY_SHELL_FEATURES` — what Ghostty sets
2. `time command ssh -G <host> 2>&1 | head -5` — confirm the hang
3. `ssh-add -l` — 1Password agent reachable?
4. `SSH_AUTH_SOCK="" command ssh -G <host>` — isolate the agent
5. `TERM=xterm-256color command ssh -G <host>` — isolate TERM
6. If still ambiguous: bisect by disabling fast-syntax-highlighting,
   `omz:lib`, zsh-abbr, and `omz:plugins/git` one at a time.
