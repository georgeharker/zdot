#!/usr/bin/env zsh
# check-docs.zsh — validate documentation cross-links and the restructure content map.
#
# Three passes:
#   1. Every relative markdown link/image in README.md and docs/*.md resolves
#      to an existing file, and its #anchor (if any) to a real heading.
#   2. Every backtick-quoted `file.md[#anchor]` token in
#      docs/restructure-content-map.md resolves the same way.
#   3. Coverage: every heading of the pre-restructure docs (from git HEAD)
#      appears in the content map, so no section was dropped silently.
#
# Exit status: number of failures (0 = clean).

emulate -L zsh
setopt extended_glob typeset_silent

local root="${0:A:h:h}"
cd "$root" || exit 1

typeset -gi errors=0
typeset -gA anchor_cache

fail() {
    print -r -- "FAIL: $1"
    (( errors++ ))
}

# GitHub-style anchor slug: lowercase, drop backticks and punctuation,
# spaces become hyphens.
slugify() {
    local h="$1"
    h="${h//\`/}"
    h="${(L)h}"
    h="${h//[^a-z0-9 _-]/}"
    h="${h// /-}"
    REPLY="$h"
}

# Cache the anchor slugs of a markdown file (duplicate slugs get -1, -2, ...
# suffixes, matching GitHub).
collect_anchors() {
    local f="$1"
    [[ -n "${anchor_cache[$f]-}" ]] && return 0
    local line text slug acc=""
    local -i in_code=0
    local -A seen
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '```'* ]]; then
            (( in_code = ! in_code ))
            continue
        fi
        (( in_code )) && continue
        [[ "$line" == ('#'##' '*) ]] || continue
        text="${line##\### }"
        slugify "$text"
        slug="$REPLY"
        if (( ${+seen[$slug]} )); then
            local -i n=$seen[$slug]
            seen[$slug]=$(( n + 1 ))
            slug="${slug}-${n}"
        else
            seen[$slug]=1
        fi
        acc+=" $slug"
    done < "$f"
    anchor_cache[$f]="$acc "
}

# check_ref <containing-file> <target>  — target like "file.md#anchor",
# "#anchor", or "path/file.png".
check_ref() {
    local from="$1" ref="$2"
    local path anchor target

    case "$ref" in
        (http://*|https://*|mailto:*) return 0 ;;
    esac

    if [[ "$ref" == *'#'* ]]; then
        path="${ref%%\#*}"
        anchor="${ref#*\#}"
    else
        path="$ref"
        anchor=""
    fi

    if [[ -z "$path" ]]; then
        target="$from"
    else
        target="${from:h}/${path}"
    fi
    target="${target:A}"

    if [[ ! -e "$target" ]]; then
        fail "$from: broken link target '$ref'"
        return 1
    fi

    if [[ -n "$anchor" && "$target" == *.md ]]; then
        collect_anchors "$target"
        if [[ "${anchor_cache[$target]}" != *" ${(L)anchor} "* ]]; then
            fail "$from: anchor '#$anchor' not found in ${path:-$from}"
            return 1
        fi
    fi
    return 0
}

# ── Pass 1: links and images in the live docs ────────────────────────────
local f l t
local -a files links
files=( README.md index.md(N) docs/*.md(N) docs/design/*.md(N) )
for f in $files; do
    links=( ${(f)"$(grep -oE '\]\([^)[:space:]]+\)' "$f" 2>/dev/null)"} )
    for l in $links; do
        t="${l#\]\(}"
        t="${t%\)}"
        check_ref "$f" "$t"
    done
done

# ── Pass 1.5: site reachability ───────────────────────────────────────────
# Every relative .md link in a RENDERED file must target another rendered
# file — a target that exists in the repo but is missing from the Quarto
# render list 404s on the published site (Quarto only rewrites links to
# rendered inputs). Mirrors Quarto's rules: explicit entries, glob entries
# (which skip README.md files), and "!" exclusions.
if [[ -f _quarto.yml ]]; then
    typeset -A rendered
    local -a render_entries excl_entries expanded
    local in_render=0 entry rf
    while IFS= read -r l; do
        if [[ $l == [[:space:]]#render: ]]; then
            in_render=1
            continue
        fi
        if (( in_render )); then
            if [[ $l == [[:space:]]##-[[:space:]]* ]]; then
                entry="${l##*- }"
                entry="${entry//\"/}"
                entry="${entry%%[[:space:]]#\#*}"   # strip inline comment
                if [[ $entry == \!* ]]; then
                    excl_entries+=("${entry#\!}")
                else
                    render_entries+=("$entry")
                fi
            elif [[ $l == [[:space:]]#\#* || -z ${l// /} ]]; then
                continue
            else
                in_render=0
            fi
        fi
    done < _quarto.yml

    for entry in $render_entries; do
        if [[ $entry == *[\*\?]* ]]; then
            for rf in ${~entry}(N); do
                [[ ${rf:t} == README.md ]] && continue   # globs skip READMEs
                expanded+=("$rf")
            done
        else
            [[ -f $entry ]] && expanded+=("$entry")
        fi
    done
    for entry in $excl_entries; do
        expanded=(${expanded:#$entry})
    done
    for rf in $expanded; do rendered[${rf:A}]=1; done

    for rf in $expanded; do
        [[ $rf == *.md ]] || continue
        links=( ${(f)"$(grep -oE '\]\([^)[:space:]]+\)' "$rf" 2>/dev/null)"} )
        for l in $links; do
            t="${l#\]\(}"
            t="${t%\)}"
            case "$t" in (http://*|https://*|mailto:*|\#*) continue ;; esac
            t="${t%%\#*}"
            [[ $t == *.md ]] || continue
            local _target="${rf:h}/${t}"
            _target="${_target:A}"
            [[ -f $_target ]] || continue   # missing files are pass-1 failures
            if [[ -z ${rendered[$_target]:-} ]]; then
                fail "$rf: links '$t' which is not in the Quarto render list (404 on the site)"
            fi
        done
    done
fi

# ── Pass 2: destinations in the content map ──────────────────────────────
local map=docs/restructure-content-map.md
if [[ -f "$map" ]]; then
    links=( ${(f)"$(grep -oE '`[^`]+\.md(#[A-Za-z0-9_-]+)?`' "$map" 2>/dev/null)"} )  # shuck: ignore=C005  # literal backticks are the delimiters being matched
    for l in $links; do
        t="${l//\`/}"
        check_ref "$map" "$t"
    done
fi

# ── Pass 3: coverage of pre-restructure sections ──────────────────────────
# Compares against the PRE-restructure docs (the main branch). Retire this
# pass together with docs/restructure-content-map.md once the restructure
# is reviewed and merged.
# check_coverage <git-rev> <path> <max-heading-depth>
check_coverage() {
    local gitrev="$1" gitpath="$2"
    local -i maxdepth="$3"
    local content line text hashes
    local -i in_code=0
    content="$(git show "${gitrev}:${gitpath}" 2>/dev/null)" || return 0
    local mapnorm="$(< $map)"
    mapnorm="${mapnorm//\`/}"
    while IFS= read -r line; do
        if [[ "$line" == '```'* ]]; then
            (( in_code = ! in_code ))
            continue
        fi
        (( in_code )) && continue
        [[ "$line" == ('#'##' '*) ]] || continue
        hashes="${line%% *}"
        (( ${#hashes} >= 2 )) || continue   # h1 is the doc title, not a section
        (( ${#hashes} <= maxdepth )) || continue
        text="${line##\### }"
        text="${text//\`/}"
        text="${text%% \(*}"         # drop trailing parenthetical
        text="${text//[[:space:]]##/ }"
        [[ "$text" == "Table of Contents" ]] && continue
        [[ ${#text} -le 3 ]] && continue   # too short to match meaningfully
        if [[ "$mapnorm" != *"$text"* ]]; then
            fail "content-map: section '$text' of HEAD:$gitpath is unaccounted for"
        fi
    done <<< "$content"
}

if [[ -f "$map" ]] && git rev-parse main >/dev/null 2>&1; then
    check_coverage main README.md 3
    check_coverage main docs/plugins.md 2
    check_coverage main docs/caching-implementation.md 2
fi

# ── Result ────────────────────────────────────────────────────────────────
if (( errors )); then
    print -r -- "check-docs: $errors failure(s)"
else
    print -r -- "check-docs: OK (${#files} files checked)"
fi
exit $errors
