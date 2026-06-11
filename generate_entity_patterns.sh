#!/usr/bin/env bash

# Regenerate every schema-derived block used by libBIDS.sh from schema.json.
# schema.json is the authoritative BIDS specification source; treat it as the
# single source of truth and paste the blocks below into libBIDS.sh verbatim.
#
# BIDS nomenclature (see schema objects.entities):
#   entity key  = schema .name        (e.g. "sub")  -> filename token
#   entity name = schema object key   (e.g. "subject") -> table column header
# rules.entities provides the canonical filename ordering of entities.

set -euo pipefail

# Entities, in canonical BIDS filename order (rules.entities).
mapfile -t entity_names < <(jq -r '.rules.entities[]' schema.json)
entity_keys=()

echo "### entities=( ) glob patterns ###"
for entity in "${entity_names[@]}"; do
  entity_key=$(jq -r ".objects.entities.${entity}.name" schema.json)
  entity_keys+=("${entity_key}")
  entity_format=$(jq -r ".objects.entities.${entity}.format" schema.json)
  if [[ ${entity_format} == "label" ]]; then
    echo "    \"*(_${entity_key}-+([a-zA-Z0-9]))\""
  elif [[ ${entity_format} == "index" ]]; then
    echo "    \"*(_${entity_key}-+([0-9]))\""
  else
    echo "Unrecognized entity_format ${entity_format}" 1>&2
    exit 1
  fi
done

echo
echo "### entities_order (entity keys, space separated) ###"
printf "%s " "${entity_keys[@]}"
echo

echo
echo "### entities_name_order (entity names / column headers, tab separated) ###"
printf "%s" "${entity_names[0]}"
printf "\\\\t%s" "${entity_names[@]:1}"
echo

echo
echo "### suffixes alternation ###"
printf '_@(%s)\n' "$(jq -r '.objects.suffixes[].value' schema.json | paste -sd'|')"

echo
echo "### extensions alternation (drops '.*' and '/', strips trailing '/') ###"
printf '@(%s)\n' "$(jq -r '.objects.extensions[].value' schema.json \
  | grep -vxF -e '.*' -e '/' -e '' \
  | sed 's:/$::' \
  | paste -sd'|')"

echo
echo "### datatype regex (for _libBIDSsh_parse_filename) ###"
printf '(%s)\n' "$(jq -r '.objects.datatypes | keys[]' schema.json | paste -sd'|')"
