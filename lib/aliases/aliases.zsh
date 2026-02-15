#!/usr/bin/env zsh
# Aliases module
# Centralizes miscellaneous custom aliases

_aliases_init() {
    # YouTube download
    alias ytdl='yt-dlp -S ext:m4a -x --embed-thumbnail'
}

# Register hook: requires plugins to be loaded and post-configured
# Aliases only needed in interactive shells
zdot_hook_register _aliases_init interactive \
    --requires plugins-post-configured \
    --provides aliases-configured
