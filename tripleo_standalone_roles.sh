#!/bin/bash
# Validate and fix tripleo standalone role vars mappings for t-h-t/hiera data
#
# Example PARAMS_FILE contents:
# SVC=nova_libvirt
# THT=tripleo-heat-templates/deployment/nova/nova-modular-libvirt-container-puppet.yaml
# # matching regex rules to deduplicate long names, like:
# # tripleo_service_component_foo_service_bar_component_subcomponent_baz
# # into: tripleo_service_component_foo_subcomponent_baz
# # (do not use regex capture groups here)
# MATCH="nova_|nova_libvirt_|nova_compute_libvirt_|nova_compute_|libvirt_|compute_"
# # base/puppet template(s) with common params and hiera data, shared with other components
# PUPPET=(
#   "tripleo-heat-templates/deployment/nova/nova-base-puppet.yaml"
#   "tripleo-heat-templates/deployment/logging/files/nova-libvirt.yaml"
# )
#
# NOTE: stripping libvirt_ subcomponent off tripleo_nova_compute_libvirt_*
# names quickly becomes misleading and breaks the mappings detection logic
#
# If it cannot match hiera mappings, adjust lookup paths in HIERALOC var

SVC=nova_libvirt
THT=tripleo-heat-templates/deployment/nova/nova-modular-libvirt-container-puppet.yaml
MATCH="nova_|nova_libvirt_|nova_compute_libvirt_|nova_compute_|libvirt_|compute_"
PUPPET=(
  "tripleo-heat-templates/deployment/nova/nova-base-puppet.yaml"
  "tripleo-heat-templates/deployment/logging/files/nova-libvirt.yaml"
)
# where to look for hiera values in $THT and $PUPPET files
HIERALOC='.outputs.role_data.value.config_settings,.outputs.config_settings.value,.resources.RoleParametersValue.properties.value'
# how to enter nested heat functions to get hiera data as top level keys
HEATFUNCS='.,.map_replace?,.map_merge?,.get_attr?,.str_replace?,.list_concat? | select(.!=null)[]'

# special names for t-h-t params and role vars to exclude from checking
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
_volumes
_environment
_idm_realm
_ansible
_config_dir
_environment
"

# overwrite above defaults from custom params file
[ -f "$PARAMS_FILE" ] && . "$PARAMS_FILE"

set -ueo pipefail
VARS=${VARS:-/opt/Projects/gitrepos/OOO/tripleo-ansible/tripleo_ansible/roles/tripleo_$SVC/defaults/main.yml}
ROLE_PATH=$(dirname $(dirname "$VARS"))

# role vars will be/expected to be prefixed with that:
PREFIX="${PREFIX:-tripleo_$SVC}_"  # empty or just tripleo_ will not work

# safety checks before running it
if [[ ! "$ROLE_PATH" =~ 'tripleo_ansible/roles/' ]] ; then
  echo "FATAL: $VARS file should be inside of the tripleo_ansible/roles/ path!"
  exit 1
fi
if ! git -C "$ROLE_PATH" diff --quiet ; then 
  echo "FATAL: Stage or commit work tree changes before running it!"
  exit 1
fi

set +e
# where to look for t-h-t params (both in $THT and $PUPPET files),
yq -r '.parameters|keys[]' ${PUPPET[@]} $THT | sort -h | tee /tmp/$SVC | \
  python -c "import fileinput; import re; print([str.strip() + ' ' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' | sort -u >  /tmp/${SVC}_snake

rm -f /tmp/${SVC}_snake_base
[ "${PUPPET[@]}" ] && yq -r '.parameters|keys[]' ${PUPPET[@]} | sort -h | tee /tmp/$SVC | \
  python -c "import fileinput; import re; print([str.strip() + ' ' + re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() for str in fileinput.input()])" | \
  yq -r '.[]' | sort -u >  /tmp/${SVC}_snake_base

# prepare group vars to wire-in for tht to call the role
yq -r '.parameters|keys[]' ${PUPPET[@]} $THT | sort -h | tee /tmp/$SVC |\
  python -c "import fileinput; import re; print([re.sub('([a-z0-9])([A-Z])', r'\1_\2', re.sub('(.)([A-Z][a-z]+)', r'\1_\2', str)).lower().strip() + ': {get_param: ' + str.strip() + '}' for str in fileinput.input()])" | \
  yq -r '.[]' | sort -u >  /tmp/${SVC}_group_vars_wire_in

# Prepare ansible config vars based on puppet base hiera data in tht
enterheatfuncs="$HEATFUNCS | select (.|type==\"object\") | to_entries[] | select(.key|type!=\"number\")"
# FIXME: this treats unqualified hiera keys as heat functions...
notheatfunc='select(.key|test("::"))'
isheatfunc='select(.key|test("::")|not)'
notobj='select (.value|type!="object")'
isobj='select (.value|type=="object")'

# filter hiera data keys with direct values and directly defined defaults
# to filter it later (to suggest default values for role vars matching hiera keys)
yq -r "$HIERALOC | $enterheatfuncs | $notheatfunc | $notobj" \
  ${PUPPET[@]} $THT > /tmp/${SVC}_config_defaults

# get direct t-h-t params substitutions in hiera values
# to filter it later (to drop role vars for hiera keys that already match other defined role vars)
yq -r "$HIERALOC | $enterheatfuncs | $isobj | select(.value.get_param!=null) | select(.value.get_param|type==\"string\")" \
  ${PUPPET[@]} $THT > /tmp/${SVC}_config_substitutions

# all data, including nested objects that requires special handling:
# cannot assume a default, nor can assume if it misses a role var or not
yq -r "$HIERALOC | $enterheatfuncs" \
  ${PUPPET[@]} $THT > /tmp/${SVC}_config_special_full
# do the best to suggest possible values
yq -r "$HIERALOC | $enterheatfuncs | $isheatfunc" \
  ${PUPPET[@]} $THT | awk -F '": ' '/::/ {if ($1) print}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/;s/,$//g;/ \{$/d' | \
  sort -u > /tmp/${SVC}_config_special

# just a bulk raw view into related $SVC hiera keys
yq -r "$HIERALOC" ${PUPPET[@]} $THT | grep  :: |\
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | \
  sort -u > /tmp/${SVC}_config

rm -f /tmp/${SVC}_config_base
[ "${PUPPET[@]}" ] && yq -r "$HIERALOC" ${PUPPET[@]} | grep  :: |\
  awk -F '": ' '/::/ {if ($1) print $1}' | \
  sed -r 's/\"//g;s/::/_/g;s/^\s+(.*)/\1/' | \
  sort -u > /tmp/${SVC}_config_base

# top scope vars dedined in svc role defaults
yq -r '. | keys[]' $VARS | sort -h > /tmp/${SVC}_sr

# new format of data for ansible config template.
# it doesn't have to map into t-h-t params, nor hiera data
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
  [ "$role_var" ] && result=0
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
  if [ $(grep -q " $p " /tmp/${SVC}_fnames | wc -l) -gt 1 ]; then
    echo "FATAL $fname: cannot be defined more than once. Stopping."
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
    echo "FATAL $n: cannot be defined more than once. Stopping."
    exit 1
  fi
  # remove ignored and irrelevant records:
  # those starting from tht param names, or coming from puppet base
  if grep -q $n <<< $IGNORE ; then
    sed -r -i "/^(${o}|${p}):/d" /tmp/${SVC}_group_vars_wire_in
    continue
  fi
  if test -f /tmp/${SVC}_snake_base && grep -q $n /tmp/${SVC}_snake_base; then
      # drop it from the list of group vars to wire-in in tht for main SVC
      sed -r -i "/^${p}:/d" /tmp/${SVC}_group_vars_wire_in
  fi
  # to find missing vars by unmatching t-h-t params
  # (do not consider it missing if is mentioned in vars file)
  if ! grep -q $n /tmp/${SVC}_sr && ! grep -q $n $VARS ; then
    if test -f /tmp/${SVC}_snake_base && grep -q $n /tmp/${SVC}_snake_base; then
      echo "INFO $fn: missing mapping to t-h-t puppet base param (ignore that)"
      continue
    else
      echo "ERROR $fn: missing mapping to t-h-t main service param!"
      continue
    fi
  fi
  # prepare string to wire-in it into ansible group vars in t-h-t of main SVC
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
  if ! grep -q $fn /tmp/${SVC}_sr && ! grep -q $fn /tmp/${SVC}_src && ! grep -q $fn $VARS ; then
    # when relaxed naming rule didn't match the original strict name,
    # fallback to orignal name in *_config as well to pick a tht default
    strict_name_match=$(sed -r "s/_|::/\(_\|::\)/g" <<< $s)
    default=$(jq -r  "select(.key|test(\"${standard_name_match}|${strict_name_match}\")) | .value" /tmp/${SVC}_config_defaults /tmp/${SVC}_config_special_full | uniq)
    if [ "${default}${lookup}" ]; then
      if test -f /tmp/${SVC}_config_base && grep -q $n /tmp/${SVC}_config_base ; then
        echo "INFO $fn: missing mapping to puppet base hiera key (ignore that): matching t-h-t value: ${lookup:-$default}"
      else
        echo "ERROR $fn: missing mapping to hiera key: matching t-h-t value: ${lookup:-$default}"
      fi
      continue
    fi
    if test -f /tmp/${SVC}_config_base && grep -q $n /tmp/${SVC}_config_base ; then
      echo "INFO $fn: missing mapping to puppet base hiera key (ignore that): see t-h-t definition: $default"
    else
      echo "ERROR $fn: missing mapping to hiera key: see t-h-t definition: $default"
    fi
    # looking for a better way to show enclosing object (heat funcs stack)
    snippet=$(grep -E -C30 "_?$standard_name_match\b" /tmp/${SVC}_config_special_full)
    [ "$snippet" ] || continue
    echo " --------- t-h-t code snippet ------------"
    echo "$snippet"
    echo " ... "
  fi
done < /tmp/${SVC}_cnames

ignored=$(printf "%s\n" $IGNORE | xargs -n1 printf "%s|")
while read p; do 
  # To remove vars not existing as t-h-t params, nor mapped in t-h-t hiera data,
  # neither the new ansible config data doesn't implement it;
  # but leaving foo_real as a valid match for a foo
  m=$(sed -r "s/^tripleo_(${MATCH}|${SVC}_|_${SVC}$)//g" <<< $p)
  m=$(sed -r "s/(\S+)_real\b/\1/g" <<< $m)
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
