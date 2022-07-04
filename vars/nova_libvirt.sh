#!/bin/bash
SVC=nova_libvirt
THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-modular-libvirt-container-puppet.yaml
MATCH="nova_|nova_libvirt_|nova_compute_libvirt_|nova_compute_|libvirt_|compute_"
PUPPET=(
  "/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-base-puppet.yaml"
  "/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/logging/files/nova-libvirt.yaml"
)
