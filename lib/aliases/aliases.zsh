#!/usr/bin/env zsh
# Aliases module
# Centralizes miscellaneous custom aliases

_aliases_init() {
    # YouTube download
    alias ytdl='yt-dlp -S ext:m4a -x --embed-thumbnail'
}

# Register hook for post-plugin phase (after plugins load their aliases)
zdot_hook_register post-plugin _aliases_init
