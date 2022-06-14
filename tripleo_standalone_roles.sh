#!/bin/bash
#
# Example:
#
#SVC=nova_libvirt
#VARS=tripleo-ansible/tripleo_ansible/roles/tripleo_$SVC/defaults/main.yml
#THT=tripleo-heat-templates/deployment/nova/nova-modular-libvirt-container-puppet.yaml
#PUPPET=... extra template for puppet/base hiera configs ...
#
# How to deduplicate redundant names like tripleo_nova_compute_(nova_) etc.
# Do not ue regex capture groups here!
# NOTE: stripping libvirt_ off tripleo_nova_compute_libvirt_*  quickly becomes misleading
#MATCH="nova_|libvirt_|compute_"

SVC=nova_compute
THT=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-compute-container-puppet.yaml
PUPPET=/opt/Projects/gitrepos/OOO/tripleo-heat-templates/deployment/nova/nova-base-puppet.yaml
MATCH="nova_|nova_libvirt_|nova_compute_"
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

if ! git diff --quiet ; then 
  echo "Stage or commit work tree changes before running it!"
  exit 1
fi

# filter out multi-world acronyms like TLSCA then normalize acronyms as camelCase
filter="sed -r 's/TLS/Tls/g;s/CA/Ca/g;s/([A-Z])([A-Z]*)([A-Z][a-z])/\1\L\2\u\3/g'"
yq -r '.parameters|keys[]' $THT | eval $filter |sort -h | tee /tmp/$SVC | \
  python -c "from pprint import pprint; import fileinput; import re; pprint([re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' >  /tmp/${SVC}_snake

# prepare group vars to wire-in for tht to call the role
yq -r '.parameters|keys[]' $THT | eval $filter |sort -h | tee /tmp/$SVC |\
  python -c "from pprint import pprint; import fileinput; import re; print([re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() + ': {get_param: ' + str.strip() + '}' for str in fileinput.input()])" | \
  yq -r '.[]' >  /tmp/${SVC}_group_vars_wire_in

# prepare ansible config vars based on puppet base hiera data in tht
namespace=".outputs.role_data.value.config_settings,.resources.RoleParametersValue.properties.value"
yq -r "$namespace" $THT | awk  '/::/ {print}' > /tmp/${SVC}_config_defaults
yq -r "$namespace" $THT | \
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | sort -u > /tmp/${SVC}_config
yq -r "$namespace" $PUPPET | awk  '/::.*[^\{]$/ {print}' >> /tmp/${SVC}_config_defaults
yq -r "$namespace" $PUPPET | \
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | sort -u >> /tmp/${SVC}_config

# top scope vars dedined in svc role defaults
yq -r '. | keys[]' $VARS | sort -h > /tmp/${SVC}_sr
# new ansible svc config data that doesn't map into t-h-t hiera data
yq -r ".tripleo_${SVC}_config" $VARS > /tmp/${SVC}_src

touch /tmp/${SVC}_fnames
# produces lines to match tht params with vars, with columns:
# original snake_case, prefix, short name (uniq key), full var name
while read p; do
  p2=$(sed -r "s/_$SVC//g" <<< $p)
  tht=$(sed -r "s/^($MATCH)|_$SVC|${SVC}_//g" <<< $p2)
  pref=$(sed -r "s/^($MATCH)\S+/\1/" <<< $p2)
  if [ "$pref" = "$tht" ] || grep -qE $MATCH <<< $pref ; then
    pref=tripleo_${SVC}_
  else
    pref="tripleo_${SVC}_${pref}"
  fi
  fname=$(sed -r "s/($SVC)_\1/\1/g;s/(tripleo_${SVC}_)($MATCH)(.*)/\1\3/g" <<< $pref$tht)
  if [ $(grep -q " $fname " /tmp/${SVC}_fnames | wc -l) -gt 1 ]; then
    echo "ERROR: $fname cannot be defined more than once. Stopping."
    exit 1
  fi
  echo $p $pref $tht $fname
done < /tmp/${SVC}_snake > /tmp/${SVC}_fnames

# produces lines with a prefix, short and full names to match puppet hiera data
# with vars
while read p; do
  p=$(sed -r "s/_$SVC//g" <<< $p)
  tht=$(sed -r "s/^($MATCH|tripleo_profile_base_)|_$SVC|${SVC}_//g" <<< $p)
  pref=$(sed -r "s/^($MATCH|tripleo_profile_base_)\S+/\1/" <<< $p)
  if [ "$pref" = "$tht" ] || [ "$pref" = "tripleo_profile_base_" ] || grep -qE $MATCH <<< $pref ; then
    pref=tripleo_${SVC}_
  else
    pref="tripleo_${SVC}_${pref}"
  fi
  # dedup repeated service names in the vars names
  # relax t-h-t following naming rules for ansible vars to keep it shorter
  fname=$(sed -r "s/($SVC)_\1/\1/g;s/(tripleo_${SVC}_)($MATCH)(.*)/\1\3/g" <<< $pref$tht)
  echo $pref $tht $fname
done < /tmp/${SVC}_config > /tmp/${SVC}_cnames

while IFS='  ' read -r o p n fn; do
  if [ $(grep -q " $n " /tmp/${SVC}_fnames | wc -l) -gt 1 ]; then
    echo "ERROR: $n cannot be defined more than once. Stopping."
    exit 1
  fi
  # To find missing vars by unmatching t-h-t params
  if grep -q $n <<< $IGNORE ; then
    sed -r -i "/^$o:/d" /tmp/${SVC}_group_vars_wire_in
    continue
  fi
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n $VARS ; then
    echo "Var for $n t-h-t param looks missing, use name $fn ?"
    continue
  fi
  # prepare string to wire-in it into ansible group vars in t-h-t
  sed -r -i "s/^$o:/$fn:/g" /tmp/${SVC}_group_vars_wire_in
done < /tmp/${SVC}_fnames

# FIXME: maybe tht keys and hiera data needs another ignore lists
while IFS='  ' read -r p n fn; do
  # To find missing vars by unmatching hiera data keys
  # (also look it up in new ansible config data)
  grep -q $n <<< $IGNORE && continue
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n /tmp/${SVC}_src && ! grep -q $n $VARS ; then
    echo "Var for $n hiera key looks missing, use:"
    default=$(grep -E "$(sed -r "s/_/\(_\|::\)/g" <<< $n)" /tmp/${SVC}_config_defaults | \
      awk -F': ' '!/\{/ {if ($2) print $2}' | tr -s ',' '\n')
    echo "${fn}: $default"
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

echo
echo "Group vars to wire-in for t-h-t to call the role:"
cat /tmp/${SVC}_group_vars_wire_in
