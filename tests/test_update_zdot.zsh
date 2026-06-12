#!/usr/bin/env zsh
# test_update_zdot.zsh — zdot's update integration, driven through dotfiler's
# shared update harness: deployment-topology detection and zdot's unpack
# phase against a sandboxed repo + link dest.
#
# Requires a dotfiler checkout. Resolution order:
#   1. $DOTFILER_SRC (explicit override, e.g. in CI)
#   2. sibling checkout: <zdot>/../dotfiler
setopt extendedglob

local zdot_src="${0:A:h:h}"
typeset -g DOTFILER_SRC="${DOTFILER_SRC:-${zdot_src:h}/dotfiler}"
if [[ ! -f "$DOTFILER_SRC/test/lib/update_harness.zsh" ]]; then
    print -u2 "test_update_zdot: dotfiler checkout not found at $DOTFILER_SRC"
    print -u2 "  set DOTFILER_SRC to a dotfiler checkout"
    exit 1
fi

source "$DOTFILER_SRC/test/lib/update_harness.zsh"
source "$zdot_src/core/logging.zsh"
source "$zdot_src/core/update-impl.zsh"   # pure functions, no source-time effects

harness_init

# ---------------------------------------------------------------------------
section "deployment topology detection"
# _update_core_detect_deployment <repo> <subtree-spec> → REPLY
check_topology() {
    local _desc=$1 _dir=$2 _spec=$3 _want=$4
    _update_core_detect_deployment "$_dir" "$_spec"
    if [[ "$REPLY" == "$_want" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      got=%s want=%s\n' "$_desc" "$REPLY" "$_want"
        (( fail++ ))
    fi
}

# standalone: zdot is its own top-level repo
fixture_repo zsolo core/zdot.zsh="solo"
zsolo="$REPLY"
check_topology "own toplevel repo" "$zsolo" "" standalone

# subdir: a plain directory inside a parent repo
fixture_repo parent1 .gitconfig="g" zdot/core/zdot.zsh="z"
parent1="$REPLY"
check_topology "plain subdirectory of a parent repo" "$parent1/zdot" "" subdir

# subtree: same layout, but a subtree-remote spec is configured
check_topology "subdirectory with subtree spec configured" \
    "$parent1/zdot" "zdot main" subtree

# submodule: registered in .gitmodules
fixture_repo zchild core/zdot.zsh="child"
zchild="$REPLY"
fixture_repo parent2 .gitconfig="g"
parent2="$REPLY"
fixture_submodule_add "$parent2" "$zchild" "zdot"
check_topology "submodule registered in .gitmodules" "$parent2/zdot" "" submodule

# none: not a git repo at all
mkdir -p "$SBX/plaindir"
check_topology "non-repo directory" "$SBX/plaindir" "" none

# ---------------------------------------------------------------------------
section "zdot unpack phase: links into the zdot link dest"
fixture_repo zrepo core/zdot.zsh="core v1" modules/fzf/init.zsh="fzf v1" \
    zdot_exclude=""
zrepo="$REPLY"
zdest="$SBX/home/.config/zdot"
mkdir -p "$zdest"

# Caller-scope vars the hook expects (update.zsh's _update_parse_args shape)
typeset -ga force=() ; typeset -g dry_run="" quiet="" debug_flag=""  # consumed by the sourced hook  # shuck: ignore=C001
typeset -g ZDOT_REPO="$zrepo"
typeset -g  _dotfiler_plan_zdot_repo_dir="$zrepo"
typeset -g  _dotfiler_plan_zdot_link_dest="$zdest"
typeset -gaU _dotfiler_plan_zdot_to_unpack
typeset -gaU _dotfiler_plan_zdot_to_remove

_dotfiler_plan_zdot_to_unpack=(core/zdot.zsh modules/fzf/init.zsh)
_dotfiler_plan_zdot_to_remove=()
_zdot_update_hook_unpack
assert_link_at    "core file linked into zdot dest" \
    "$zdest/core/zdot.zsh" "$zrepo/core/zdot.zsh"
assert_link_at    "module file linked into zdot dest" \
    "$zdest/modules/fzf/init.zsh" "$zrepo/modules/fzf/init.zsh"
assert_content_at "content readable through zdot link" \
    "$zdest/core/zdot.zsh" "core v1"

# upstream content change is visible without re-unpack
print -r -- "core v2" > "$zrepo/core/zdot.zsh"
assert_content_at "repo change visible through existing link" \
    "$zdest/core/zdot.zsh" "core v2"

# removals: planned symlinks are removed, real files are preserved
_dotfiler_plan_zdot_to_unpack=()
_dotfiler_plan_zdot_to_remove=(modules/fzf/init.zsh)
_zdot_update_hook_unpack
assert_absent_at "planned removal unlinks from zdot dest" \
    "$zdest/modules/fzf/init.zsh"

print -r -- "user content" > "$zdest/userfile"
_dotfiler_plan_zdot_to_remove=(userfile)
_zdot_update_hook_unpack
assert_content_at "removal preserves a real (non-symlink) file" \
    "$zdest/userfile" "user content"

# nothing planned + not forced → genuine no-op
_dotfiler_plan_zdot_to_unpack=()
_dotfiler_plan_zdot_to_remove=()
rm -f "$zdest/core/zdot.zsh"
_zdot_update_hook_unpack
assert_absent_at "no-op when nothing planned and not forced" \
    "$zdest/core/zdot.zsh"

# force semantics: with EMPTY plans the hook is still a no-op (full
# unpacks are the setup path's job); with planned files, force switches
# the unpack to -U, which replaces a divergent regular file with the link.
force=(-f)
_zdot_update_hook_unpack
assert_absent_at "force with empty plans is still a no-op" \
    "$zdest/core/zdot.zsh"

# force = consent: the hook passes -y when forced, so a non-interactive
# forced update replaces a divergent regular file with the link.
print -r -- "local divergence" > "$zdest/core/zdot.zsh"
_dotfiler_plan_zdot_to_unpack=(core/zdot.zsh)
_zdot_update_hook_unpack
assert_link_at "forced unpack replaces a divergent file with the link" \
    "$zdest/core/zdot.zsh" "$zrepo/core/zdot.zsh"
rm -f "$zdest/core/zdot.zsh"
force=()
_dotfiler_plan_zdot_to_unpack=()

# …but a NON-forced unpack of the same divergence refuses non-interactively
# (no -y): never silently clobber local edits without explicit consent.
print -r -- "local divergence" > "$zdest/core/zdot.zsh"
_dotfiler_plan_zdot_to_unpack=(core/zdot.zsh)
_zdot_update_hook_unpack
assert_content_at "non-forced unpack refuses divergent replacement" \
    "$zdest/core/zdot.zsh" "local divergence"
rm -f "$zdest/core/zdot.zsh"
_dotfiler_plan_zdot_to_unpack=()

# link-tree=false disables the phase entirely
zstyle ':zdot:update' link-tree false
rm -f "$zdest/core/zdot.zsh"
_dotfiler_plan_zdot_to_unpack=(core/zdot.zsh)
_zdot_update_hook_unpack
assert_absent_at "link-tree=false disables zdot unpack" "$zdest/core/zdot.zsh"
zstyle -d ':zdot:update' link-tree

harness_summary
