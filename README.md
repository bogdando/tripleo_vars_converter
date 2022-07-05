# tripleo_vars_converter
Validate and fix tripleo standalone role vars mappings for t-h-t/hiera data

Usage:
* Define a tripleo service specific vars file
* Adjust local paths for tripleo repositories in the script body
* Commit or stash changes in the tripleo-ansible repo local path
* Run validation like:
  ```
  PARAMS_FILE=vars/nova_migration_target.sh bash tripleo_standalone_roles.sh
  ```
* Modify the service specific standalone ansible role vars following provided hints
