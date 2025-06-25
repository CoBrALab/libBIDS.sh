#!/usr/bin/env bash

set -euo pipefail

entities_order=($(jq -r .rules.entities.[] schema.json))
entities_names_ordered=()

for entity in ${entities_order[@]}; do
  entity_name=$(jq -r .objects.entities.${entity}.name schema.json)
  entities_names_ordered+=(${entity_name})
  entity_format=$(jq -r .objects.entities.${entity}.format schema.json)
  if [[ ${entity_format} == "label" ]]; then
    echo \""*(_${entity_name}-+([a-zA-Z0-9]))"\"
  elif [[ ${entity_format} == "index" ]]; then
    echo \""*(_${entity_name}-+([0-9]))"\"
  else
    echo "Unrecognized entity_format ${entity_format}" 1>&2
    exit 1
  fi
done

printf "%s," ${entities_order[@]}
echo
printf "%s " ${entities_names_ordered[@]}
echo
