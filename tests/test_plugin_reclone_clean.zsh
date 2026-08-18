#!/usr/bin/env zsh
# test_plugin_reclone_clean.zsh — zdot plugin reclone / clean, the shared
# bundle-aware target resolver (_zdot_plugins_resolve_targets), and the guards
# that back the risk fixes:
#   * reclone re-clones immediately and git-safely (dirty repo is skipped, never
#     clobbered);
#   * clean purges by spec / --all / --remove-unused;
#   * bundle sub-specs collapse to their shared backing repo and WARN-but-continue;
#   * resolver out-params are namespaced (_zdot_rt_*) — no generic global leak;
#   * everything survives a hostile `setopt ksharrays` (emulate -L zsh guard).
#
# Self-contained: builds throwaway local git fixtures + a fake bundle handler,
# no network, no dotfiler. Modelled on test_plugin_submodules.zsh.
setopt extendedglob

local zdot_src="${0:A:h:h}"

# ---------------------------------------------------------------------------
# Isolated git + throwaway root. Nothing here touches the real ~/.gitconfig or
# home; production code is unchanged — it just inherits the env.
# ---------------------------------------------------------------------------
typeset -g _tmproot
_tmproot=$(mktemp -d "${TMPDIR:-/tmp}/zdot-reclone-test.XXXXXX") || exit 1
trap 'rm -rf "$_tmproot"' EXIT INT TERM

export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$_tmproot/gitconfig"
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = zdot test
	email = test@zdot.invalid
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF

gitc() { command git -C "$1" "${@:2}" >/dev/null 2>&1 }

# ---------------------------------------------------------------------------
# Code under test.
# ---------------------------------------------------------------------------
source "$zdot_src/core/logging.zsh"
source "$zdot_src/core/plugins.zsh"
fpath=("$zdot_src/core/functions" $fpath)
autoload -Uz zdot_reclone_plugins zdot_clean_plugins zdot_update_plugin

# ---------------------------------------------------------------------------
# Logging stubs. Warnings are captured so we can assert on the bundle notice;
# everything else is quiet (we assert on filesystem + reply state).
# ---------------------------------------------------------------------------
typeset -ga WARNLOG
zdot_info()    { : }
zdot_action()  { : }
zdot_success() { : }
zdot_warn()    { WARNLOG+=("$*") }
zdot_error()   { WARNLOG+=("ERR: $*") }

# ---------------------------------------------------------------------------
# Mini harness
# ---------------------------------------------------------------------------
typeset -gi pass=0 fail=0
section() { print -- "\n== $1 ==" }
ok()   { (( ++pass )) }
bad()  { printf 'FAIL  %s\n' "$1"; (( ++fail )) }
assert_eq()      { if [[ "$2" == "$3" ]]; then ok; else bad "$1 (got='$2' want='$3')"; fi }
assert_present() { if [[ -e "$2" ]]; then ok; else bad "$1 (missing: $2)"; fi }
assert_absent()  { if [[ ! -e "$2" ]]; then ok; else bad "$1 (still present: $2)"; fi }
assert_file() {
    local g=""
    [[ -f "$2" ]] && g=$(<"$2")
    if [[ "$g" == "$3" ]]; then ok; else bad "$1 (got='$g' want='$3')"; fi
}
warned() { (( ${WARNLOG[(I)*$1*]} )) }   # true if any captured warning matches *pat*
assert_warned()    { if warned "$2"; then ok; else bad "$1 (no warning matched '*$2*')"; fi }
assert_not_warned(){ if warned "$2"; then bad "$1 (unexpected warning '*$2*')"; else ok; fi }

# ---------------------------------------------------------------------------
# Fixtures: bare "remotes" under $_tmproot/remotes, cloned into the cache.
# ---------------------------------------------------------------------------
mkremote() {  # <spec> <content>
    local spec=$1 content=$2
    local work="$_tmproot/work/$spec"
    local bare="$_tmproot/remotes/$spec.git"
    mkdir -p "$work"; command git init -q "$work"
    print -r -- "$content" > "$work/f"; gitc "$work" add f; gitc "$work" commit -qm "$content"
    gitc "$work" branch -M main
    mkdir -p "${bare:h}"; command git clone -q --bare "$work" "$bare" >/dev/null 2>&1
    gitc "$work" remote add origin "$bare"
}
bump_remote() {  # <spec> <content>
    local spec=$1 content=$2
    local work="$_tmproot/work/$spec"
    print -r -- "$content" > "$work/f"; gitc "$work" add f; gitc "$work" commit -qm "$content"
    gitc "$work" push -q origin HEAD:main
}
clone_into_cache() {  # <spec>
    local spec=$1
    mkdir -p "${_ZDOT_PLUGINS_CACHE}/${spec:h}"
    command git clone -q "$_tmproot/remotes/$spec.git" "$_ZDOT_PLUGINS_CACHE/$spec" >/dev/null 2>&1
    command git -C "$_ZDOT_PLUGINS_CACHE/$spec" remote set-head origin --auto >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# A real bundle handler: every fake:* spec is backed by one shared/bundle repo
# (mirrors how omz:* all share ohmyzsh/ohmyzsh). Plus a repo-less bundle to
# exercise the skip path.
# ---------------------------------------------------------------------------
zdot_bundle_fake_match() { [[ $1 == fake:* ]] }
zdot_bundle_fake_repo()  { REPLY="$_ZDOT_PLUGINS_CACHE/shared/bundle" }
zdot_bundle_fake_path()  { REPLY="$_ZDOT_PLUGINS_CACHE/shared/bundle/${1#fake:}" }
zdot_bundle_fake_url()   { REPLY="$_tmproot/remotes/shared/bundle.git" }
zdot_bundle_fake_name()  { REPLY="fake-bundle" }
zdot_register_bundle fake
# Pin the bundle-repo set to exactly our fixture — sourcing plugins.zsh can seed
# _ZDOT_BUNDLE_REPOS with real bundles (e.g. ohmyzsh/ohmyzsh) at source time, and
# --all resolves against it; we want a hermetic set.
typeset -ga _ZDOT_BUNDLE_REPOS=( shared/bundle )

zdot_bundle_norepo_match() { [[ $1 == norepo:* ]] }   # matches but exposes no _repo hook
zdot_register_bundle norepo

# The clone URL for plain specs points at our local fixtures, not github.
zdot_plugin_url() { REPLY="$_tmproot/remotes/${1%@*}.git" }

typeset -g  _ZDOT_PLUGINS_CACHE="$_tmproot/cache"
typeset -g  _ZDOT_PLUGINS_INITIALIZED=1        # so _zdot_plugins_init is a no-op
typeset -gA _ZDOT_PLUGINS_VERSION
mkdir -p "$_ZDOT_PLUGINS_CACHE"

# ===========================================================================
section "resolver: dedup, bundle flag, skip count, and no generic global leak"
# ===========================================================================
typeset -ga _ZDOT_PLUGINS_ORDER=( me/alpha me/beta fake:plugin )
# _ZDOT_BUNDLE_REPOS already has shared/bundle (from zdot_use_bundle above).

_zdot_plugins_resolve_targets 0 fake:plugin fake:other
# shuck: ignore=C006  # _zdot_rt_* set by _zdot_plugins_resolve_targets (reply-return)
assert_eq   "two bundle sub-specs collapse to one target"  "${#_zdot_rt_spec}" "1"      # shuck: ignore=C006
assert_eq   "collapsed target is the shared backing repo"  "${_zdot_rt_spec[1]}" "shared/bundle"  # shuck: ignore=C006
assert_eq   "collapsed target is flagged bundle-affecting" "${_zdot_rt_bundle[1]}" "1"  # shuck: ignore=C006

_zdot_plugins_resolve_targets 0 me/alpha
assert_eq   "plain spec is not bundle-affecting"           "${_zdot_rt_bundle[1]}" "0"  # shuck: ignore=C006

_zdot_plugins_resolve_targets 0 norepo:x
assert_eq   "repo-less bundle spec yields no target"       "${#_zdot_rt_spec}" "0"      # shuck: ignore=C006
assert_eq   "repo-less bundle spec counts as skipped"      "$REPLY" "1"

# #3 guard: the resolver must not leave generic reply_* globals lying around.
assert_eq   "no generic reply_spec global leaked"          "${+reply_spec}" "0"
assert_eq   "no generic reply_dir global leaked"           "${+reply_dir}" "0"

# ===========================================================================
section "reclone re-clones immediately and fetches the latest remote state"
# ===========================================================================
mkremote me/alpha r1; clone_into_cache me/alpha
bump_remote me/alpha r2
assert_file "cache starts at r1"                           "$_ZDOT_PLUGINS_CACHE/me/alpha/f" "r1"
zdot_reclone_plugins me/alpha
assert_file "reclone produced a fresh clone at r2"         "$_ZDOT_PLUGINS_CACHE/me/alpha/f" "r2"

# ===========================================================================
section "reclone is git-safe: a dirty repo is skipped, not clobbered"
# ===========================================================================
mkremote me/beta r1; clone_into_cache me/beta
bump_remote me/beta r2
print -r -- "local-hack" > "$_ZDOT_PLUGINS_CACHE/me/beta/f"    # uncommitted change
zdot_reclone_plugins me/beta
assert_file "dirty repo preserved (not reset to r2)"      "$_ZDOT_PLUGINS_CACHE/me/beta/f" "local-hack"

# ===========================================================================
section "reclone --all + bundle warn-but-continue"
# ===========================================================================
command git -C "$_ZDOT_PLUGINS_CACHE/me/beta" checkout -q -- f    # un-dirty beta
mkremote shared/bundle b1; clone_into_cache shared/bundle
bump_remote me/alpha r3; bump_remote me/beta r3; bump_remote shared/bundle b2
WARNLOG=()
zdot_reclone_plugins --all
assert_file "reclone --all refetched me/alpha"           "$_ZDOT_PLUGINS_CACHE/me/alpha/f" "r3"
assert_file "reclone --all refetched me/beta"            "$_ZDOT_PLUGINS_CACHE/me/beta/f" "r3"
assert_file "reclone --all refetched shared bundle repo" "$_ZDOT_PLUGINS_CACHE/shared/bundle/f" "b2"
assert_warned "reclone --all warned about the shared bundle repo" "shared bundle repo"

# ===========================================================================
section "reclone --dry-run changes nothing but still warns on bundles"
# ===========================================================================
bump_remote me/alpha r4
WARNLOG=()
zdot_reclone_plugins --all --dry-run
assert_file "dry-run left me/alpha untouched"            "$_ZDOT_PLUGINS_CACHE/me/alpha/f" "r3"
assert_warned "dry-run warned about the shared bundle repo" "shared bundle repo"

# ===========================================================================
section "clean purges a single spec, and --all purges everything declared"
# ===========================================================================
zdot_clean_plugins me/alpha
assert_absent "clean <spec> removed me/alpha"            "$_ZDOT_PLUGINS_CACHE/me/alpha"
assert_present "clean <spec> left me/beta"               "$_ZDOT_PLUGINS_CACHE/me/beta"

WARNLOG=()
zdot_clean_plugins --all
assert_absent "clean --all removed me/beta"              "$_ZDOT_PLUGINS_CACHE/me/beta"
assert_absent "clean --all removed shared bundle repo"   "$_ZDOT_PLUGINS_CACHE/shared/bundle"
assert_warned "clean --all warned about the shared bundle repo" "shared bundle repo"

# ===========================================================================
section "clean --remove-unused prunes undeclared + corrupt, keeps declared"
# ===========================================================================
mkremote me/alpha r1; clone_into_cache me/alpha          # re-establish a declared clone
mkremote other/orphan z1; clone_into_cache other/orphan  # undeclared leftover
mkdir -p "$_ZDOT_PLUGINS_CACHE/bad:dir"                   # corrupt colon dir
zdot_clean_plugins --remove-unused
assert_present "declared me/alpha kept"                  "$_ZDOT_PLUGINS_CACHE/me/alpha"
assert_absent  "undeclared other/orphan pruned"         "$_ZDOT_PLUGINS_CACHE/other"
assert_absent  "corrupt colon dir removed"              "$_ZDOT_PLUGINS_CACHE/bad:dir"

# ===========================================================================
section "#4 guard: reclone works under a hostile 'setopt ksharrays'"
# ===========================================================================
bump_remote me/alpha r9
setopt ksharrays                      # would break 1-based ${arr[i]} without emulate -L zsh
zdot_reclone_plugins me/alpha
unsetopt ksharrays
assert_file "reclone survived ksharrays (emulate -L zsh)" "$_ZDOT_PLUGINS_CACHE/me/alpha/f" "r9"

# ===========================================================================
section "update (resolver-driven) still pulls and honours pins"
# ===========================================================================
mkremote up/plug u1; clone_into_cache up/plug
local pin_sha; pin_sha=$(command git -C "$_tmproot/work/up/plug" rev-parse HEAD)
bump_remote up/plug u2
typeset -ga _ZDOT_PLUGINS_ORDER=( up/plug )
zdot_update_plugin up/plug
assert_file "update pulled to u2"                         "$_ZDOT_PLUGINS_CACHE/up/plug/f" "u2"
_ZDOT_PLUGINS_VERSION=( up/plug "$pin_sha" )
zdot_update_plugin up/plug
assert_file "update honoured the pin (back to u1)"        "$_ZDOT_PLUGINS_CACHE/up/plug/f" "u1"

# ---------------------------------------------------------------------------
print -- "\n${pass} passed, ${fail} failed"
(( fail == 0 ))
