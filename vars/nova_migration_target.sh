#!/bin/bash
SVC=nova_migration_target
THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-migration-target-container-puppet.yaml
MATCH="nova_|nova_migration_|nova_migration_target_|migration_|target_|docker_nova_migration_|container_nova_compute_|container_nova_libvirt_"
PUPPET=("")
HEATFUNCS='.,.map_replace?,.map_merge?,.get_attr?,.str_replace?,.list_concat? | select(.!=null)'
