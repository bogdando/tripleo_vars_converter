#!/bin/bash
# Example:
SVC=nova_compute
THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-compute-container-puppet.yaml
PUPPET=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-base-puppet.yaml

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
_ansible
_config_dir
_environment
idmm
admin_password
DEFAULT
"

# filter out multi-world acronyms like TLSCA then normalize acronyms as camelCase
filter="sed -r 's/TLS/Tls/g;s/CA/Ca/g;s/([A-Z])([A-Z]*)([A-Z][a-z])/\1\L\2\u\3/g'"
yq -r '.parameters|keys[]' $THT | eval $filter |sort -h | tee /tmp/$SVC | \
  python -c "from pprint import pprint; import fileinput; import re; pprint([re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' >  /tmp/${SVC}_snake

# prepare group vars to wire-in for tht to call the role
yq -r '.parameters|keys[]' $THT | eval $filter |sort -h | tee /tmp/$SVC |\
  python -c "from pprint import pprint; import fileinput; import re; print([str.strip() + ': \"{{ ' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() + ' }}\"' for str in fileinput.input()])" | \
  yq -r '.[]' >  /tmp/${SVC}_group_vars_wire_in

# prepare ansible config vars based on puppet base hiera data in tht
yq -r '.outputs.role_data.value.config_settings,.resources.RoleParametersValue.properties.value' $THT | \
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | sort -u > /tmp/${SVC}_config
yq -r '.outputs.role_data.value.config_settings,.resources.RoleParametersValue.properties.value' $PUPPET | \
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | sort -u >> /tmp/${SVC}_config

# top scope vars dedined in svc role defaults
yq -r '. | keys[]' $VARS | sort -h > /tmp/${SVC}_sr
# new ansible svc config data that doesn't map into t-h-t hiera data
yq -r ".tripleo_${SVC}_config" $VARS > /tmp/${SVC}_src

# produces lines with a prefix, short and full names to match tht params with vars
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
done < /tmp/${SVC}_snake > /tmp/${SVC}_fnames

# produces lines with a prefix, short and full names to match puppet hiera data
# with vars
while read p; do
  p=$(sed -r "s/_$SVC//g" <<< $p)
  tht=$(sed -r "s/^$MATCH|tripleo_profile_base_|_$SVC|$SVC_//g" <<< $p)
  pref=$(sed -r "s/^($MATCH|tripleo_profile_base_)\S+/\1/" <<< $p)
  if [ "$pref" = "$tht" ] || [ "$pref" = "tripleo_profile_base_" ]; then
    pref=tripleo_${SVC}_
  else
    pref="tripleo_${SVC}_${pref}"
  fi
  fname=$(sed -r "s/($SVC)_\1/\1/g" <<< $pref$tht)
  echo $pref $tht $fname
done < /tmp/${SVC}_config > /tmp/${SVC}_cnames

while IFS='  ' read -r p n fn; do
  if [ $(grep " $n " /tmp/${SVC}_fnames | wc -l) -gt 1 ]; then
    echo "ERROR: $n cannot be defined more than once. Stopping."
    exit 1
  fi
  # To find missing vars by unmatching t-h-t params
  grep -q $n <<< $IGNORE && continue
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n $VARS ; then
    echo "Var for $n t-h-t param looks missing, use name $fn ?"
    continue
  fi
  # prepare string to wire-in it into ansible group vars in t-h-t
  sed -r -i "s/ $n / $fn /g" /tmp/${SVC}_group_vars_wire_in
done < /tmp/${SVC}_fnames

# FIXME: maybe tht keys and hiera data needs another ignore lists
while IFS='  ' read -r p n fn; do
  # To find missing vars by unmatching hiera data keys
  # (also look it up in new ansible config data)
  grep -q $n <<< $IGNORE && continue
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n /tmp/${SVC}_src && ! grep -q $n $VARS ; then
    echo "Var for $n hiera key looks missing, use name $fn ?"
  fi
done < /tmp/${SVC}_cnames

ignored=$(printf "%s\n" $IGNORE | xargs -n1 printf "%s|")
while read p; do 
  # To remove vars not existing as t-h-t params, nor mapped in t-h-t hiera data,
  # neither the new ansible config data doesn't implement it;
  # but leaving foo_real as a valid match for a foo
  m=$(sed -r "s/^tripleo_($MATCH|${SVC}_|_${SVC}$)//g" <<< $p)
  m=$(sed -r "s/(\S+)_real/\1/g" <<< $m)
  grep -q -E $m <<< $IGNORE && continue
  grep -q -E "${ignored%|*}" <<< $m && continue
  if ! grep -q $m /tmp/${SVC}_fnames && ! grep -q $m /tmp/${SVC}_cnames && ! grep -q $m /tmp/${SVC}_src; then
    echo "Var for $m looks redundant and has been deleted"
    sed -ri "/^$p:/d" "$VARS"
  fi
done < /tmp/${SVC}_sr

echo "Group vars to wire-in for t-h-t to call the role:"
cat /tmp/${SVC}_group_vars_wire_in
