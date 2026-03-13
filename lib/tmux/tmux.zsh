#!/usr/bin/env zsh
# tmux: OMZ tmux plugin integration

zdot_define_module tmux \
    --load-plugins omz:plugins/tmux \
    --context interactive \
    --auto-bundle
