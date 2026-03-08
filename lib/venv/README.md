# lib/venv — Python Virtual Environment Module

Provides shell-level Python virtual environment management built on top of
[uv](https://docs.astral.sh/uv/). Handles the default Python version, global
venv activation, and exposes three utility functions for creating, recreating,
and activating project venvs.

## Requirements

- `uv` — used for venv creation and package installation (`lib/uv` provides this)
- `python3` — see version configuration below

---

## Python version selection

The module sets a `DEFAULT_PYTHON_VERSION` that is used by `nvenv` and `rvenv`
when no version is explicitly provided. The value is OS-specific and
configurable via zstyle.

| zstyle | Default | Used on |
|---|---|---|
| `':zdot:venv' python-version-macos` | `$(command -v python3.14)` | macOS |
| `':zdot:venv' python-version-linux` | `cpython@3.14.0` | Linux |

Set these in your `.zshrc` or a user module before `zdot_init`:

```zsh
zstyle ':zdot:venv' python-version-macos '/opt/homebrew/bin/python3.13'
zstyle ':zdot:venv' python-version-linux 'cpython@3.13.0'
```

### macOS — why Homebrew Python?

On macOS the default resolves to a Homebrew-installed Python binary (e.g.
`/opt/homebrew/bin/python3.14`) rather than a uv-managed or system Python.

This is an **opinionated choice** with a specific technical reason: the macOS
dynamic linker (`dyld`) enforces strict library path validation. Python
extensions that link against Homebrew libraries (e.g. `numpy` against
`libopenblas`, `Pillow` against `libjpeg`, `psycopg2` against `libpq`) must
be linked against the same copy of those libraries that the interpreter was
built against.

Homebrew's Python is built against Homebrew's own copies of those libraries
and carries the correct `@rpath` and `LC_RPATH` entries. A uv-managed
CPython download (which is built for portability) typically lacks those
entries, causing `ImportError: dlopen(...) image not found` at runtime for
any extension that pulls in a Homebrew-linked `.dylib`.

**In short:** if you use Homebrew to install native libraries and then pip-install
Python packages that wrap them, use a Homebrew Python as your base interpreter.
uv can still manage the venv itself and install packages — only the *base
interpreter* needs to be Homebrew-sourced.

`UV_NO_MANAGED_PYTHON=1` is exported on macOS to prevent uv from silently
substituting its own CPython when the requested version is not found.

### Linux — uv managed Python

On Linux there is no equivalent dyld constraint. uv's managed CPython
distributions are portable and self-contained, so `UV_MANAGED_PYTHON=1` is
exported to let uv download and cache the interpreter automatically if it is
not already present.

---

## Global venv

On startup, if `~/.venv/bin/activate` exists it is sourced automatically.
This is the conventional location for a user-global venv containing
system-wide tools (linters, formatters, language servers) that should always
be on `$PATH` regardless of the active project.

Create it once with:

```zsh
uv venv --system-site-packages ~/.venv
```

---

## Functions

All functions are autoloaded on first call.

### `nvenv [python_version [venv_dir]]`

Create a new virtual environment.

- `python_version` — defaults to `$DEFAULT_PYTHON_VERSION`
- `venv_dir` — defaults to `.venv`

Creates the venv with `--system-site-packages` and `--seed` (pre-installs
`pip`, `setuptools`, `wheel`).

```zsh
nvenv                          # .venv with default Python
nvenv python3.12               # .venv with python3.12
nvenv python3.12 .myvenv       # .myvenv with python3.12
```

### `rvenv [python_version [venv_dir]]`

Recreate an existing virtual environment, preserving installed packages.

1. Activates the existing venv and freezes packages to `/tmp/requirements.<date>.txt`
2. Strips version pins from the requirements file (keeps package names only)
3. Moves the old venv to `<venv_dir>.backup.<date>`
4. Creates a fresh venv with `nvenv`
5. Re-installs packages from the stripped requirements with `uv pip install -r`

Useful when upgrading Python versions or recovering from a broken interpreter.

```zsh
rvenv                          # recreate .venv with default Python
rvenv python3.13               # recreate .venv with python3.13
```

### `avenv [venv_dir]`

Activate a virtual environment.

- `venv_dir` — defaults to `.venv`

```zsh
avenv          # activate .venv
avenv .myvenv  # activate .myvenv
```

---

## Aliases

Three aliases for PyPy venv workflows are registered by the module:

| Alias | Expands to | Purpose |
|---|---|---|
| `npvenv` | `nvenv pypy3 .pypyvenv` | Create a PyPy venv at `.pypyvenv` |
| `rpvenv` | `rvenv pypy3 .pypyvenv` | Recreate the PyPy venv |
| `apvenv` | `avenv .pypyvenv` | Activate the PyPy venv |
