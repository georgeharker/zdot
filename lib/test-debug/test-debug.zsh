#!/usr/bin/env zsh
# Test module to debug zsh_module_dir

echo "At top of test module, zsh_module_dir returns:"
zdot_module_dir

echo ""
echo "Functions directory would be:"
echo "$(zdot_module_dir)/functions"

echo ""
echo "Calling zsh_module_autoload_funcs..."
zsh_module_autoload_funcs

echo ""
echo "After autoload, fpath is:"
echo "$fpath"
