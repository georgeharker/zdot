
# API improvements

- need a module and a plugin function to add an entire dir of functions / zsh files to the fpath and have glob of zsh / sh files compiled (glob needs to be controllable as some plugins use .sh as the bash variant, some use it for all shell).
- is zdot_define_module sufficient to be able to declare a set of plugins all at once to be instantiated and loaded.
    - goal a simple zshrc conversion which users with monolithic plugin setups currently could trivially replace their "load plugins section" of their zshrc with
    - if not lets design that migration path / enhance zdot_define_module to work for that
    - a different func might be best to express intent even if we extend zdot_define_module

Suggest and discuss before implementation.

# separable self-update from dotfiler

- right now this is integrated with dotfiler with the presumption being that dotfile contains all these files and self-update relies on that
- I'd like to design a similar update-check selfupdate mechanism that allows for zdot coming from it's own directory / submodule of .dotfiles

# Composable reusable modules

- Evalutate which modules need ot be made more generic to be reusable by users (rather than specific to my setup)
- This might include zstyle parameterization of the secrets module (including a group-based configure set to be invoked before secrets to control it's behavior)
- venv vs nodejs - there's a conceptual naming issue here, and I want to think about those bits 
- similarly shell plugin?
- better use of group based hooks to allow user-specific stuff to be brought in whilst using the same framework.

Suggest and discuss before implementation.
