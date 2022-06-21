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

# Role vars will be/expected to be prefixed with that:
PREFIX="tripleo_${SVC}_"  # or just tripleo_

ROLE_PATH=$(dirname $(dirname "$VARS"))

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
  echo "FATAL: Stage or commit work tree changes before running it!"
  exit 1
fi
if [[ ! "$ROLE_PATH" =~ 'tripleo_ansible/roles/' ]] ; then
  echo "FATAL: $VARS file should be inside of the tripleo_ansible/roles/ path!"
  exit 1
fi

# where to look for t-h-t params (both in $THT and $PUPPET files)
# filter out multi-world acronyms like TLSCA then normalize acronyms as camelCase
filter="sed -r 's/TLS/Tls/g;s/CA/Ca/g;s/([A-Z])([A-Z]*)([A-Z][a-z])/\1\L\2\u\3/g'"
yq -r '.parameters|keys[]' $PUPPET $THT | eval $filter |sort -h | tee /tmp/$SVC | \
  python -c "import fileinput; import re; print([str.strip() + ' ' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' | sort -u >  /tmp/${SVC}_snake

yq -r '.parameters|keys[]' $PUPPET | eval $filter |sort -h | tee /tmp/$SVC | \
  python -c "import fileinput; import re; print([str.strip() + ' ' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' | sort -u >  /tmp/${SVC}_snake_base

# prepare group vars to wire-in for tht to call the role
yq -r '.parameters|keys[]' $PUPPET $THT | eval $filter |sort -h | tee /tmp/$SVC |\
  python -c "import fileinput; import re; print([re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() + ': {get_param: ' + str.strip() + '}' for str in fileinput.input()])" | \
  yq -r '.[]' | sort -u >  /tmp/${SVC}_group_vars_wire_in

# Prepare ansible config vars based on puppet base hiera data in tht

# where to look for hiera values (both in $THT and $PUPPET files)
hieraloc='.outputs.role_data.value.config_settings,.resources.RoleParametersValue.properties.value'
# enter topscope funcs having the same output data view (like with and w/o map_merge)
enterheatfuncs='.,.map_replace?,.map_merge?,.get_attr?,.str_replace?,.list_concat? | select(.!=null)[] | to_entries[] | select(.key|type!="number")'
# is (not/) a heat func
notheatfunc='select(.key|test("^(if$|map_|list_|get_|str_)")|not)'
isheatfunc='select(.key|test("^(if$|map_|list_|get_|str_)"))'
# is (not/) an object
notobj='select (.value|type!="object")'
isobj='select (.value|type=="object")'

# filter hiera data keys with direct values and directly defined defaults
# to filter it later (to suggest default values for role vars matching hiera keys)
yq -r "$hieraloc | $enterheatfuncs | $notheatfunc | $notobj" \
  $PUPPET $THT > /tmp/${SVC}_config_defaults

# get direct t-h-t params substitutions in hiera values
# to filter it later (to drop role vars for hiera keys that already match other defined role vars)
yq -r "$hieraloc | $enterheatfuncs | $isobj | select(.value.get_param!=null) | select(.value.get_param|type==\"string\")" \
  $PUPPET $THT > /tmp/${SVC}_config_substitutions

# get complex hiera data (conditions/templating) that requires special handling:
# cannot assume a default, nor can assume if it misses a role var or not
yq -r "$hieraloc | $enterheatfuncs | $isobj " \
  $PUPPET $THT > /tmp/${SVC}_config_special_full
# do the best to suggest possible values
yq -r "$hieraloc | $enterheatfuncs | $isheatfunc" \
  $PUPPET $THT | awk -F '": ' '/::/ {if ($1) print}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/;s/,$//g;/ \{$/d' | \
  sort -u > /tmp/${SVC}_config_special

# just a bulk raw view into related $SVC hiera keys
yq -r "$hieraloc" $PUPPET $THT | grep  :: |\
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | \
  sort -u > /tmp/${SVC}_config

# top scope vars dedined in svc role defaults
yq -r '. | keys[]' $VARS | sort -h > /tmp/${SVC}_sr


# new ansible svc config data that doesn't map into t-h-t hiera data
yq -r ".tripleo_${SVC}_config" $VARS > /tmp/${SVC}_src


# used during variables deduplication run
# returns 1 - no duplicates found,
# or 0 - found duplicates in mappings
dedup() {
  local fn="$1"
  local tht_param="$2"
  local standard_name_match="$3"
  local keyname="${4:-}"
  local msg
  local role_var=$(awk "BEGIN{IGNORECASE=1}; /^$tht_param / {print \$NF}" /tmp/${SVC}_fnames)
  local result=1

  if [ "$keyname" ]; then
    msg="$keyname: {get_param: $tht_param}"
  else
    msg="direct assignment of $tht_param"
  fi

  if [ "$role_var" ] && [ "$role_var" != "$fn" ] && ! grep -qE "$standard_name_match" <<< $role_var ; then
    if grep -qE "\b${fn}\b" /tmp/${SVC}_sr && grep -qE "\b${role_var}\b" /tmp/${SVC}_sr; then
      echo "WARNING $fn: remove dup of $role_var: $msg"
      sed -ri "/^${fn}:/d" "$VARS"
      result=0
    fi
    if grep -qE "\b${fn}\b" /tmp/${SVC}_sr; then
      echo "WARNING $fn: rename all to $role_var: $tht_param wins over hiera mapping"
      grep -rE "\b${fn}\b" "$ROLE_PATH" |\
        awk -F':' '{print $1}' | sort -u |\
        xargs -r -n1 -I{} sed -ri "s/\b${fn}\b/${role_var}/g" {}
      result=0
    fi
  fi
  [ "$role_var" ] && [ "$role_var" != "$fn" ] && result=0
  return $result
}

# MAIN
touch /tmp/${SVC}_fnames
# produces lines to match tht params with vars, with columns:
# tht param as is, tht param snake_case, prefix, short name (uniq key), full role var name
while read -r o p; do
  p2=$(sed -r "s/_${SVC}//g" <<< $p)
  tht=$(sed -r "s/^($MATCH)|_${SVC}|${SVC}_//g" <<< $p2)
  pref=$(sed -r "s/^($MATCH)\S+/\1/" <<< $p2)
  if [ "$pref" = "$tht" ] || grep -qE $MATCH <<< $pref ; then
    pref=${PREFIX}
  else
    pref=${PREFIX}${pref}
  fi
  fname=$(sed -r "s/($SVC)_\1/\1/g;s/(tripleo_${SVC}_)($MATCH)(.*)/\1\3/g" <<< $pref$tht)
  if [ $(grep -q " $fname " /tmp/${SVC}_fnames | wc -l) -gt 1 ]; then
    echo "ERROR $fname: cannot be defined more than once. Stopping."
    exit 1
  fi
  echo $o $p $pref $tht $fname
done < /tmp/${SVC}_snake > /tmp/${SVC}_fnames

# produces lines with
# strict name, prefix, short name (uniq key) and full role var name,
# to match puppet hiera data with role vars
while read p; do
  p2=$(sed -r "s/_${SVC}//g" <<< $p)
  tht=$(sed -r "s/^(${MATCH}|tripleo_profile_base_)|_${SVC}|${SVC}_//g" <<< $p2)
  pref=$(sed -r "s/^(${MATCH}|tripleo_profile_base_)\S+/\1/" <<< $p2)
  if [ "$pref" = "$tht" ] || [ "$pref" = "tripleo_profile_base_" ] || grep -qE $MATCH <<< $pref ; then
    pref=${PREFIX}
  else
    pref=${PREFIX}${pref}
  fi
  # dedup repeated service names in the vars names
  # relax t-h-t following naming rules for ansible vars to keep it shorter
  fname=$(sed -r "s/($SVC)_\1/\1/g;s/(tripleo_${SVC}_)($MATCH)(.*)/\1\3/g" <<< $pref$tht)
  echo $p $pref $tht $fname
done < /tmp/${SVC}_config > /tmp/${SVC}_cnames

# tht param as is, tht param snake_case, prefix, short name (uniq key), full role var name
while IFS='  ' read -r o p pr n fn; do
  if [ $(grep -q " $n " /tmp/${SVC}_fnames | wc -l) -gt 1 ]; then
    echo "ERROR $n: cannot be defined more than once. Stopping."
    exit 1
  fi
  # To find missing vars by unmatching t-h-t params
  if grep -q $n <<< $IGNORE ; then
    sed -r -i "/^${o}:/d" /tmp/${SVC}_group_vars_wire_in
    continue
  fi
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n $VARS ; then
    if grep -q $n /tmp/${SVC}_snake_base ; then
      echo "INFO $fn: missing mapping to t-h-t puppet base param (ignore that)"
      continue
    else
      echo "ERROR $fn: missing mapping to t-h-t main service param!"
      continue
    fi
  fi
  # prepare string to wire-in it into ansible group vars in t-h-t
  sed -r -i "s/^${p}:/${fn}:/g" /tmp/${SVC}_group_vars_wire_in
done < /tmp/${SVC}_fnames

# strict name, prefix, short name (uniq key), full role var name
while IFS='  ' read -r s p n fn; do
  # find hiera mapped role vars duplicated by role vars mapped to tht params
  standard_name_match=$(sed -r "s/_|::/\(_\|::\)/g" <<< $n)
  lookup=$(grep -m1 -E "_?${standard_name_match}\b" /tmp/${SVC}_config_special)
  # does looked up hiera data match a direct tht param mapping?
  tht_param=$(awk -F': ' '{print $2}'<<< $lookup)
  [ "$tht_param" ] && dedup $fn $tht_param $standard_name_match && continue
  # also search for duplicates mapped by get_param
  tht_param=$(jq -r "select(.key|test(\"${standard_name_match}\")) | .value.get_param" /tmp/${SVC}_config_substitutions)
  keyname=$(jq -r "select(.key|test(\"${standard_name_match}\")) | .key" /tmp/${SVC}_config_substitutions)
  [ "$tht_param" ] && dedup $fn $tht_param $standard_name_match $keyname && continue
  
  # find missing vars by unmatching hiera data keys,
  # also look it up in new ansible config data var names
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n /tmp/${SVC}_src && ! grep -q $n $VARS ; then
    # when relaxed naming rule didn't match the original strict name,
    # fallback to orignal name in *_config as well to pick a tht default
    strict_name_match=$(sed -r "s/_|::/\(_\|::\)/g" <<< $s)
    default=$(jq -r  "select(.key|test(\"${standard_name_match}|${strict_name_match}\")) | .value" /tmp/${SVC}_config_defaults /tmp/${SVC}_config_special_full)
    if [ "${default}${lookup}" ]; then
      echo "ERROR $fn: mapping to hiera key looks missing: matching t-h-t value: ${lookup:-$default}"
      continue
    fi
    echo "ERROR $fn: mapping to hiera key looks missing: see t-h-t definition: $default"
    # looking for a better way to show enclosing object (heat funcs stack)
    snippet=$(grep -E -C10 "_?$standard_name_match\b" /tmp/${SVC}_config_special_full)
    [ "$snippet" ] || continue
    echo " --------- code snipped ------------"
    echo "$snippet"
  fi
done < /tmp/${SVC}_cnames

ignored=$(printf "%s\n" $IGNORE | xargs -n1 printf "%s|")
while read p; do 
  # To remove vars not existing as t-h-t params, nor mapped in t-h-t hiera data,
  # neither the new ansible config data doesn't implement it;
  # but leaving foo_real as a valid match for a foo
  m=$(sed -r "s/^tripleo_(${MATCH}|${SVC}_|_${SVC}$)//g" <<< $p)
  m=$(sed -r "s/(\S+)_real/\1/g" <<< $m)
  grep -q $m <<< $IGNORE && continue
  grep -q -E "${ignored%|*}" <<< $m && continue
  if ! grep -q $m /tmp/${SVC}_fnames && ! grep -q $m /tmp/${SVC}_cnames && ! grep -q $m /tmp/${SVC}_src; then
    echo "WARNING $m: removed as redundant: no t-h-t param, nor hiera mapping found"
    sed -ri "/^${p}:/d" "$VARS"
  fi
  # also remove redundant var that map hiera data directly substituted by other vars
done < /tmp/${SVC}_sr

echo
echo "INFO: Group vars to wire-in for t-h-t to call the role:"
cat /tmp/${SVC}_group_vars_wire_in
