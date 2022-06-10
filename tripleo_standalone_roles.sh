#!/bin/bash
# Example:
SVC=nova_compute
THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-compute-container-puppet.yaml

#SVC=nova_libvirt
#THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-modular-libvirt-container-puppet.yaml
MATCH="nova_(libvirt_|compute_)?"
VARS=/opt/Projects/gitrepos/OOO/tripleo-ansible/tripleo_ansible/roles/tripleo_$SVC/defaults/main.yml

IGNORE="
service_net_map
service_data
role_parameters
role_name
endpoint_map
_debug
_hide_sensitive_logs
_network
_volume
_environment
_idm_realm
idmm
admin_password
"

# filter out multi-world acronyms like TLSCA then normalize acronyms as camelCase
filter="sed -r 's/TLS/Tls/g;s/CA/Ca/g;s/([A-Z])([A-Z]*)([A-Z][a-z])/\1\L\2\u\3/g'"
yq -r '.parameters|keys[]' $THT | eval $filter |sort -h | tee /tmp/$SVC | \
  python -c "from pprint import pprint; import fileinput; import re; pprint([re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' >  /tmp/${SVC}_snake

yq -r '.parameters|keys[]' $THT | eval $filter |sort -h | tee /tmp/$SVC |\
  python -c "from pprint import pprint; import fileinput; import re; print([str.strip() + ': \"{{ ' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() + ' }}\"' for str in fileinput.input()])" | \
  yq -r '.[]' >  /tmp/${SVC}_group_vars_wire_in

yq -r '. | keys[]' $VARS | sort -h > /tmp/${SVC}_sr

# produces lines with a prefix, short and full names
while read p; do
  p=$(sed -r "s/_$SVC//g" <<< $p)
  tht=$(sed -r "s/^$MATCH|_$SVC|$SVC_//g" <<< $p)
  pref=$(sed -r "s/^($MATCH)\S+/\1/" <<< $p)
  if [ "$pref" = "$tht" ]; then
    pref=tripleo_${SVC}_
  else
    pref="tripleo_${SVC}_${pref}"
  fi
  fname=$(sed -r "s/($SVC)_\1/\1/g" <<< $pref$tht)
  echo $pref $tht $fname
done < /tmp/${SVC}_snake > /tmp/fnames

while IFS='  ' read -r p n fn; do
  # To find missing vars by unmatching t-h-t params
  grep -q $n <<< $IGNORE && continue
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n $VARS ; then
    echo "Var for $n looks missing, use name $fn ?"
  fi
done < /tmp/fnames

while read p; do 
  # To remove vars not existing as t-h-t params,
  # but leaving foo_real as a valid match for a foo
  m=$(sed -r "s/^tripleo_($MATCH|${SVC}_|_${SVC}$)//g" <<< $p)
  m=$(sed -r "s/(\S+)_real/\1/g" <<< $m)
  grep -q -E $m <<< $IGNORE && continue
  grep -q -E "_volume|_environment|_network|_idm_realm" <<< $m && continue
  if ! grep -q $m /tmp/fnames; then
    echo "Var for $m looks redundant and has been deleted"
    sed -ri "/^$p:/d" "$VARS"
  fi
done < /tmp/${SVC}_sr
