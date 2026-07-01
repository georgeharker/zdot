#!/usr/bin/env zsh
# test_plugin_submodules.zsh — plugins with git submodules must clone AND stay
# in sync across every operation that moves HEAD. Regression guard for the gap
# where `git clone --recurse-submodules` populated submodules on install but
# the bare fetch/checkout/pull update paths left them stale (or, for a
# newly-added submodule, absent). See _zdot_plugin_sync_submodules.
#
# Self-contained: builds throwaway local git fixtures, no network, no dotfiler.
setopt extendedglob

local zdot_src="${0:A:h:h}"

# ---------------------------------------------------------------------------
# Isolated git environment. file:// submodules are blocked by default since
# git 2.38 (CVE-2022-39253); allow them for the fixtures via a throwaway global
# config that also supplies a committer identity. Nothing here touches the real
# ~/.gitconfig, and production code is unchanged — it just inherits the env.
# ---------------------------------------------------------------------------
typeset -g _tmproot
_tmproot=$(mktemp -d "${TMPDIR:-/tmp}/zdot-submod-test.XXXXXX") || exit 1
trap 'rm -rf "$_tmproot"' EXIT INT TERM

export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$_tmproot/gitconfig"
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = zdot test
	email = test@zdot.invalid
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
[advice]
	detachedHead = false
EOF

gitc() { command git -C "$1" "${@:2}" >/dev/null 2>&1 }

# ---------------------------------------------------------------------------
# Load the code under test. plugins.zsh defines _zdot_plugin_sync_submodules,
# zdot_plugin_clone, zdot_plugin_url/repo/name. zdot_update_plugin is autoloaded
# from its function dir (its trailing self-call is the autoload compat shim).
# ---------------------------------------------------------------------------
source "$zdot_src/core/logging.zsh"
source "$zdot_src/core/plugins.zsh"
fpath=("$zdot_src/core/functions" $fpath)
autoload -Uz zdot_update_plugin

# Quiet the logging helpers — we assert on filesystem state, not chatter.
zdot_info()    { : }
zdot_action()  { : }
zdot_success() { : }
zdot_warn()    { print -u2 "WARN: $*" }
zdot_error()   { print -u2 "ERROR: $*" }

# ---------------------------------------------------------------------------
# Mini test harness
# ---------------------------------------------------------------------------
typeset -gi pass=0 fail=0
section() { print -- "\n== $1 ==" }
ok()   { (( ++pass )) }
bad()  { printf 'FAIL  %s\n' "$1"; (( ++fail )) }
assert_file_content() {
    local desc=$1 file=$2 want=$3 got
    if [[ ! -f "$file" ]]; then bad "$desc (missing: $file)"; return; fi
    got=$(<"$file")
    if [[ "$got" == "$want" ]]; then ok; else bad "$desc (got='$got' want='$want')"; fi
}

# ---------------------------------------------------------------------------
# Fixtures: a submodule repo (sub.git) and an outer repo (outer.git) that
# vendors it at vendor/sub. Everything lives under $_tmproot.
# ---------------------------------------------------------------------------
build_sub_v1() {
    local work="$_tmproot/sub-work"
    command git init -q "$work"
    print -r -- "v1" > "$work/subfile"
    gitc "$work" add subfile
    gitc "$work" commit -qm "sub v1"
    command git clone -q --bare "$work" "$_tmproot/sub.git"
    gitc "$work" remote add origin "$_tmproot/sub.git"
}
bump_sub_v2() {
    local work="$_tmproot/sub-work"
    print -r -- "v2" > "$work/subfile"
    gitc "$work" add subfile
    gitc "$work" commit -qm "sub v2"
    gitc "$work" push -q origin HEAD:main
}
build_outer_with_sub() {
    local work="$_tmproot/outer-work"
    command git init -q "$work"
    print -r -- "outer" > "$work/plugin.zsh"
    gitc "$work" add plugin.zsh
    gitc "$work" commit -qm "outer init"
    gitc "$work" -c protocol.file.allow=always submodule add -q "$_tmproot/sub.git" vendor/sub
    gitc "$work" commit -qm "add vendor/sub @ v1"
    command git clone -q --bare "$work" "$_tmproot/outer.git"
    gitc "$work" remote add origin "$_tmproot/outer.git"
}

build_sub_v1
build_outer_with_sub

# ---------------------------------------------------------------------------
section "_zdot_plugin_sync_submodules is a silent no-op without .gitmodules"
# ---------------------------------------------------------------------------
plain="$_tmproot/plain"
command git init -q "$plain"; print x > "$plain/f"; gitc "$plain" add f; gitc "$plain" commit -qm x
errout=$(_zdot_plugin_sync_submodules "plain" "$plain" 2>&1)
if [[ -z "$errout" ]]; then ok; else bad "no-op emitted output: $errout"; fi

# ---------------------------------------------------------------------------
section "zdot_plugin_clone populates submodules"
# ---------------------------------------------------------------------------
typeset -g _ZDOT_PLUGINS_CACHE="$_tmproot/cache"
# Point the clone URL at the local fixture instead of github.
zdot_plugin_url() { REPLY="$_tmproot/outer.git" }
zdot_plugin_clone "vendor/outer" >/dev/null 2>&1
assert_file_content "clone fetches submodule working tree" \
    "$_ZDOT_PLUGINS_CACHE/vendor/outer/vendor/sub/subfile" "v1"

# ---------------------------------------------------------------------------
section "zdot_update_plugin bumps an existing submodule"
# ---------------------------------------------------------------------------
# Upstream advances the submodule pointer to v2.
bump_sub_v2
outer_work="$_tmproot/outer-work"
gitc "$outer_work" -C vendor/sub fetch -q origin
gitc "$outer_work" -C vendor/sub checkout -q origin/main
gitc "$outer_work" add vendor/sub
gitc "$outer_work" commit -qm "bump vendor/sub -> v2"
gitc "$outer_work" push -q origin HEAD:main

# Register the cloned plugin so zdot_update_plugin can resolve its repo dir.
typeset -ga _ZDOT_PLUGINS_ORDER=("vendor/outer")
zdot_update_plugin "vendor/outer" >/dev/null 2>&1
assert_file_content "update syncs bumped submodule to new commit" \
    "$_ZDOT_PLUGINS_CACHE/vendor/outer/vendor/sub/subfile" "v2"

# ---------------------------------------------------------------------------
section "zdot_update_plugin initializes a newly-added submodule (--init)"
# ---------------------------------------------------------------------------
# A second submodule appears upstream after the plugin was already cloned.
gitc "$outer_work" -c protocol.file.allow=always submodule add -q "$_tmproot/sub.git" vendor/extra
gitc "$outer_work" commit -qm "add vendor/extra"
gitc "$outer_work" push -q origin HEAD:main
zdot_update_plugin "vendor/outer" >/dev/null 2>&1
assert_file_content "update initializes brand-new submodule" \
    "$_ZDOT_PLUGINS_CACHE/vendor/outer/vendor/extra/subfile" "v2"

# ---------------------------------------------------------------------------
print -- "\n${pass} passed, ${fail} failed"
(( fail == 0 ))
