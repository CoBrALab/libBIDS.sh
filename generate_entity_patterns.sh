#!/usr/bin/env bash

# Regenerate every schema-derived block used by libBIDS.sh from schema.json.
# schema.json is the authoritative BIDS specification source; treat it as the
# single source of truth and paste the blocks below into libBIDS.sh verbatim.
#
# BIDS nomenclature (see schema objects.entities):
#   entity key  = schema .name        (e.g. "sub")  -> filename token
#   entity name = schema object key   (e.g. "subject") -> table column header
# rules.entities provides the canonical filename ordering of entities.
#
# The parser matches files by suffix and extension only. The entity lists are
# used for the table columns, not for matching.

set -euo pipefail

# Entities, in canonical BIDS filename order (rules.entities).
mapfile -t entity_names < <(jq -r '.rules.entities[]' schema.json)
entity_keys=()

for entity in "${entity_names[@]}"; do
  entity_keys+=("$(jq -r ".objects.entities.${entity}.name" schema.json)")
done

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
echo "### directory-type extensions (find prunes these; the directory is one row) ###"
jq -r '.objects.extensions[].value' schema.json | grep -v -x -F '/' | sed -n 's:/$::p' \
  | paste -sd' '

echo
echo "### table stems (rules.files.common.tables with a stem; '*' is phenotype/<name>) ###"
jq -r '.rules.files.common.tables[] | select(.stem != null) | .stem' schema.json \
  | paste -sd' '

echo
echo "### datatype regex (anchored to a whole path component; for _libBIDSsh_parse_filename) ###"
printf '(^|/)(%s)$\n' "$(jq -r '.objects.datatypes | keys[]' schema.json | paste -sd'|')"
