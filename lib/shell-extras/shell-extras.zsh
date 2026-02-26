#!/usr/bin/env zsh
# shell-extras: git, eza, ssh, debian OMZ plugins

_shell_extras_configure() {
    zstyle ':omz:plugins:eza' 'dirs-first' yes
    zstyle ':omz:plugins:eza' 'git-status' yes
    zstyle ':omz:plugins:eza' 'icons' yes
}

# Custom loader needed for conditional debian plugin
_shell_extras_load() {
    zdot_load_plugin omz:plugins/git
    zdot_load_plugin omz:plugins/eza
    zdot_load_plugin omz:plugins/ssh
    if [[ $(uname -v 2>/dev/null) == *"Debian"* || $(uname -v 2>/dev/null) == *"Ubuntu"* ]]; then
        zdot_load_plugin omz:plugins/debian
    fi
}

zdot_use_plugin omz:plugins/git
zdot_use_plugin omz:plugins/eza
zdot_use_plugin omz:plugins/ssh
zdot_use_plugin omz:plugins/debian

zdot_define_module shell-extras \
    --configure _shell_extras_configure \
    --load _shell_extras_load \
    --group omz-plugins \
    --requires plugins-cloned omz-bundle-initialized
