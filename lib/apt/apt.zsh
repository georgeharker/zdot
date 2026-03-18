#!/usr/bin/env zsh
# apt: Debian package manager environment
# Declares tool availability for Debian-based systems

_apt_init() {
    # .zshrc only loads this module on Debian, but guard defensively
    zdot_is_debian || return 0

    zdot_verify_tools_zstyle ':zdot:apt' op eza oh-my-posh gh tailscale zoxide rg bat fd
}

# Tool list: override via zstyle ':zdot:apt' verify-tools <tool...>
zdot_provides_tool_args ':zdot:apt' op eza oh-my-posh gh tailscale zoxide rg bat fd
zdot_simple_hook apt --requires xdg-configured env-configured --provides apt-ready \
    "${reply[@]}"
