#!/usr/bin/env zsh
# shell-extras: git, eza, ssh, debian OMZ plugins

_shell_extras_configure() {
    # Set eza defaults only if the user has not already configured them.
    # Override any of these before this module loads, e.g. in a configure hook:
    #   zstyle ':omz:plugins:eza' 'dirs-first' no
    local _val
    zstyle -s ':omz:plugins:eza' 'dirs-first' _val || zstyle ':omz:plugins:eza' 'dirs-first' yes
    zstyle -s ':omz:plugins:eza' 'git-status' _val || zstyle ':omz:plugins:eza' 'git-status' yes
    zstyle -s ':omz:plugins:eza' 'icons'      _val || zstyle ':omz:plugins:eza' 'icons'      yes
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
