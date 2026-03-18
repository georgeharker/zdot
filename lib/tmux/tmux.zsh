#!/usr/bin/env zsh
# tmux: OMZ tmux plugin integration with SSH auto-start behaviour

_tmux_configure() {
    # Unicode support always on
    ZSH_TMUX_UNICODE="true"

    # Auto-start tmux on SSH connections, unless already inside a multiplexer
    # or the user has opted out via ~/.notmux
    if [[ -n "${SSH_CONNECTION}" ]]; then
        if [[ "${TERM}" =~ "^screen-.*" || "${TERM}" =~ "^tmux-.*" || -f ~/.notmux ]]; then
            ZSH_TMUX_AUTOSTART="false"
            ZSH_TMUX_AUTOQUIT="false"
        else
            ZSH_TMUX_AUTOSTART="true"
            ZSH_TMUX_AUTOSTART_ONCE="true"
            ZSH_TMUX_AUTOCONNECT="true"
        fi
    fi
}

zdot_define_module tmux \
    --configure _tmux_configure \
    --load-plugins omz:plugins/tmux \
    --context interactive \
    --auto-bundle
