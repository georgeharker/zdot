# Quickstart: dotfiler + zdot from scratch

This guide gets you from nothing to a working dotfiles repo managed by
[dotfiler](https://github.com/georgeharker/dotfiler) with zdot handling your
zsh configuration. It assumes macOS or Linux with git and zsh already installed.

---

## What you end up with

```
~/.dotfiles/                         ← your dotfiles git repo
  .config/
    zdot/                            ← zdot (git submodule)
    dotfiler/
      hooks/
        zdot.zsh -> ../../zdot/core/dotfiler-hook.zsh
    zsh/
      .zshrc                         ← your zshrc, managed by dotfiler

~/.config/                           ← linktree (symlinks into ~/.dotfiles)
  zdot/  -> ~/.dotfiles/.config/zdot/
  zsh/   -> ~/.dotfiles/.config/zsh/
```

dotfiler keeps `~/.dotfiles` up to date and manages the `~/.config` symlink
tree. zdot loads from `~/.config/zdot` at shell startup.

---

## Step 1 — Install dotfiler

```zsh
git clone https://github.com/georgeharker/dotfiler ~/.dotfiles/.nounpack/dotfiler
```

Add dotfiler's CLI to your `PATH` temporarily so you can use it before zdot is
wired up:

```zsh
export PATH="$HOME/.dotfiles/.nounpack/dotfiler:$PATH"
```

---

## Step 2 — Create your dotfiles repo

```zsh
mkdir -p ~/.dotfiles
cd ~/.dotfiles
git init
```

Tell dotfiler where the repo lives (it defaults to `~/.dotfiles`, but being
explicit avoids surprises):

```zsh
export DOTFILES="$HOME/.dotfiles"
```

---

## Step 3 — Add zdot as a submodule

```zsh
cd ~/.dotfiles
git submodule add https://github.com/georgeharker/zdot .config/zdot
git submodule update --init --recursive
```

---

## Step 4 — Create a minimal `.zshrc`

Create `~/.dotfiles/.config/zsh/.zshrc`:

```zsh
# Source zdot
source "${XDG_CONFIG_HOME:-$HOME/.config}/zdot/zdot.zsh"

# Load the modules you want — start minimal, add more later
zdot_load_module xdg
zdot_load_module shell
zdot_load_module brew         # macOS only
zdot_load_module completions

# Run everything
zdot_init
```

Commit it:

```zsh
cd ~/.dotfiles
git add .config/zsh/.zshrc
git commit -m "add initial zshrc"
```

---

## Step 5 — Register the zdot hook with dotfiler

This creates a symlink in your repo that tells dotfiler zdot is a managed
component:

```zsh
dotfiler setup --bootstrap-hook ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh --yes
```

---

## Step 6 — Unpack the linktree

```zsh
dotfiler setup -u
```

This creates the symlinks in `~/.config/` and installs the hook at
`~/.config/dotfiler/hooks/zdot.zsh`. After this step your shell is live.

---

## Step 7 — Enable zdot self-updates (optional)

Add to your `.zshrc` before `zdot_init`:

```zsh
zstyle ':zdot:update' mode prompt    # ask before updating at shell start
```

And for submodule pin auto-commits (so the dotfiles repo tracks zdot's version):

```zsh
zstyle ':dotfiler:update' in-tree-commit auto
```

---

## Step 8 — Start a new shell

```zsh
exec zsh
```

zdot loads, modules initialise in dependency order, and dotfiler will check for
updates at the next login shell.

---

## Day-to-day

| Task | Command |
|---|---|
| Pull updates for dotfiles + zdot | `dotfiler update` |
| Re-unpack after manual repo changes | `dotfiler setup -u` |
| Add a new module | `zdot_load_module <name>` in `.zshrc`, then `exec zsh` |
| Customise a built-in module | `zdot module clone <name>` |
| Debug zdot loading | `zdot_debug_info` |

---

## Bootstrap on a new machine

Once your dotfiles repo is on a remote (GitHub, etc.) and you're setting up a
new machine:

```zsh
# 1. Install dotfiler
git clone https://github.com/georgeharker/dotfiler ~/.dotfiles/.nounpack/dotfiler
export PATH="$HOME/.dotfiles/.nounpack/dotfiler:$PATH"

# 2. Clone your dotfiles
git clone <your-repo-url> ~/.dotfiles
git -C ~/.dotfiles submodule update --init --recursive

# 3. Unpack everything (reads hook directly from repo, no linktree needed yet)
DOTFILES=~/.dotfiles dotfiler setup --bootstrap
```

After `--bootstrap` completes the linktree is in place and subsequent shells
use `dotfiler update` as normal.

---

## Further reading

- [dotfiler Integration](../README.md#dotfiler-integration) — adding zdot to an existing dotfiler repo
- [dotfiler zdot-integration.md](https://github.com/georgeharker/dotfiler/blob/main/docs/zdot-integration.md) — full reference: topology options, update lifecycle, symlink chain details
- [zstyle-reference.md](zstyle-reference.md) — all configuration options
- [module-guide.md](module-guide.md) — writing your own modules
