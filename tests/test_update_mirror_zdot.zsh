#!/usr/bin/env zsh
# test_update_mirror_zdot.zsh — end-to-end mirroring for zdot across its
# deployment topologies (standalone, submodule, subtree --squash): upstream
# zdot commits (modify / add / delete / rename) flow through plan + zdot's
# unpack hook in production order (plan pre-merge → content move → unpack),
# and the link dest's on-disk state mirrors upstream.
#
# The plan step uses the production builder over the range each topology's
# plan_fn would resolve (standalone: HEAD..origin/main; submodule: the
# pointer range inside the submodule; subtree: the child-history range
# between synced SHAs, i.e. what the SHA-marker logic computes). Initial
# deploys use an explicit file list — in production that's setup's job, and
# the plan builder deliberately skips the parentless root commit.
# hook_check/pull/post per topology remain future work.
setopt extendedglob

local zdot_src="${0:A:h:h}"
typeset -g DOTFILER_SRC="${DOTFILER_SRC:-${zdot_src:h}/dotfiler}"
if [[ ! -f "$DOTFILER_SRC/test/lib/update_harness.zsh" ]]; then
    print -u2 "test_update_mirror_zdot: dotfiler checkout not found at $DOTFILER_SRC"
    exit 1
fi

source "$DOTFILER_SRC/test/lib/update_harness.zsh"
source "$zdot_src/core/logging.zsh"
source "$zdot_src/core/update-impl.zsh"

harness_init

# Caller-scope vars the hook expects  # shuck: ignore=C001
typeset -ga force=() ; typeset -g dry_run="" quiet="" debug_flag=""
typeset -gaU _dotfiler_plan_zdot_to_unpack _dotfiler_plan_zdot_to_remove
typeset -gaU _update_core_files_to_unpack=() _update_core_files_to_remove=()

# zdot_plan <repo> <range> — production plan into the zdot plan arrays
zdot_plan() {
    plan_run "$1" "$2"
    _dotfiler_plan_zdot_to_unpack=("${_update_core_files_to_unpack[@]}")
    _dotfiler_plan_zdot_to_remove=("${_update_core_files_to_remove[@]}")
}

# zdot_unpack <repo> <dest> — run the unpack hook against repo/dest with
# whatever is currently in the zdot plan arrays
zdot_unpack() {
    typeset -g ZDOT_REPO="$1"
    typeset -g _dotfiler_plan_zdot_repo_dir="$1"
    typeset -g _dotfiler_plan_zdot_link_dest="$2"
    _zdot_update_hook_unpack >/dev/null 2>&1
}

# zdot_initial_deploy <repo> <dest> — explicit-list bootstrap (setup's job
# in production; the plan builder skips the parentless root commit)
zdot_initial_deploy() {
    _dotfiler_plan_zdot_to_unpack=(core/zdot.zsh modules/old/init.zsh themes/alpha)
    _dotfiler_plan_zdot_to_remove=()
    zdot_unpack "$1" "$2"
}

# upstream_batch <repo> — the four change kinds, committed upstream
upstream_batch() {
    fixture_commit "$1" "modify+add" core/zdot.zsh="core v2" modules/new/init.zsh="new mod"
    fixture_commit "$1" "delete" --rm=modules/old/init.zsh
    fixture_commit "$1" "rename" --mv=themes/alpha:themes/beta
}

# assert_mirror <label> <repo> <dest> — post-update disk expectations
assert_mirror() {
    local _l=$1 _repo=$2 _dest=$3
    assert_content_at "$_l: modified content through link" "$_dest/core/zdot.zsh" "core v2"
    assert_link_at    "$_l: added module linked"   "$_dest/modules/new/init.zsh" "$_repo/modules/new/init.zsh"
    assert_absent_at  "$_l: deleted module unlinked" "$_dest/modules/old/init.zsh"
    assert_absent_at  "$_l: rename source unlinked"  "$_dest/themes/alpha"
    assert_link_at    "$_l: rename dest linked"      "$_dest/themes/beta" "$_repo/themes/beta"
    assert_content_at "$_l: rename dest content"     "$_dest/themes/beta" "theme-a"
}

ZFILES=(core/zdot.zsh="core v1" modules/old/init.zsh="old mod" \
        themes/alpha="theme-a" zdot_exclude="")

# ---------------------------------------------------------------------------
section "topology: standalone (own clone, origin ahead)"
fixture_repo zsolo "${ZFILES[@]}"
solo="$REPLY"
fixture_origin "$solo"
git clone -q "$REPLY" "$SBX/repos/solo-peer"

dest="$SBX/home/.config/zdot-solo"; mkdir -p "$dest"
zdot_initial_deploy "$solo" "$dest"
assert_content_at "standalone: initial deploy" "$dest/core/zdot.zsh" "core v1"

upstream_batch "$SBX/repos/solo-peer"
git -C "$SBX/repos/solo-peer" push -q origin main
# Production order: fetch → plan (pre-merge range) → merge → unpack
git -C "$solo" fetch -q origin
zdot_plan "$solo" "HEAD..origin/main"
git -C "$solo" merge -q --ff-only origin/main
zdot_unpack "$solo" "$dest"
assert_mirror "standalone" "$solo" "$dest"

# ---------------------------------------------------------------------------
section "topology: submodule (parent pointer bump)"
fixture_repo zsub "${ZFILES[@]}"
zsub="$REPLY"
fixture_repo subparent .gitconfig="g"
parent="$REPLY"
fixture_submodule_add "$parent" "$zsub" "zdot"
subco="$parent/zdot"

dest="$SBX/home/.config/zdot-sub"; mkdir -p "$dest"
zdot_initial_deploy "$subco" "$dest"
assert_content_at "submodule: initial deploy" "$dest/core/zdot.zsh" "core v1"

upstream_batch "$zsub"
git -C "$subco" fetch -q origin
zdot_plan "$subco" "HEAD..origin/main"           # pointer range, pre-move
git -C "$subco" checkout -q origin/main          # the bump's content move
git -C "$parent" add zdot && git -C "$parent" commit -qm "bump zdot"
zdot_unpack "$subco" "$dest"
assert_mirror "submodule" "$subco" "$dest"

# ---------------------------------------------------------------------------
section "topology: subtree --squash (parent pull)"
fixture_repo ztree "${ZFILES[@]}"
ztree="$REPLY"
fixture_repo treeparent .gitconfig="g"
tparent="$REPLY"
synced_sha=$(repo_sha "$ztree")                  # what the SHA marker records
fixture_subtree_add "$tparent" "$ztree" "zdot" --squash
treeco="$tparent/zdot"

dest="$SBX/home/.config/zdot-tree"; mkdir -p "$dest"
zdot_initial_deploy "$treeco" "$dest"
assert_content_at "subtree: initial deploy" "$dest/core/zdot.zsh" "core v1"

upstream_batch "$ztree"
# zdot's subtree plan: child-history range from the synced marker to tip;
# files are then sourced from the parent's subtree working copy.
zdot_plan "$ztree" "${synced_sha}..HEAD"
fixture_subtree_pull "$tparent" "$ztree" "zdot" --squash   # the content move
zdot_unpack "$treeco" "$dest"
assert_mirror "subtree" "$treeco" "$dest"

harness_summary
