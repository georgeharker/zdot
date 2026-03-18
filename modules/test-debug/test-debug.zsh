#!/usr/bin/env zsh
# Test module to debug zdot_module_dir

zdot_info "At top of test module, zdot_module_dir returns:"
zdot_module_dir

zdot_info ""
zdot_info "Functions directory would be:"
zdot_module_dir
zdot_info "${REPLY}/functions"

zdot_info ""
zdot_info "Calling zdot_module_autoload_funcs..."
zdot_module_autoload_funcs

zdot_info ""
zdot_info "After autoload, fpath is:"
zdot_info "$fpath"
