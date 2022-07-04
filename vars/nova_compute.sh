#!/bin/bash
SVC=nova_compute
THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-compute-container-puppet.yaml
MATCH="nova_|nova_libvirt_|nova_compute_" 
PUPPET=(
  "/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-base-puppet.yaml"
)
