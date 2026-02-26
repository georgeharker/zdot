#!/usr/bin/env zsh
# apt: Debian package manager environment
# Declares tool availability for Debian-based systems

_apt_init() {
    # .zshrc only loads this module on Debian, but guard defensively
    zdot_is_debian || return 0

    zdot_verify_tools op eza oh-my-posh gh tailscale zoxide rg bat fd
}

# Register hooks - requires xdg-configured, provides tool availability on Debian
zdot_simple_hook apt --requires xdg-configured env-configured --provides apt-ready \
    --provides-tool op --provides-tool eza --provides-tool oh-my-posh \
    --provides-tool gh --provides-tool tailscale --provides-tool zoxide \
    --provides-tool rg --provides-tool bat --provides-tool fd
