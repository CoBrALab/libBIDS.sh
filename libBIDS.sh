#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "Error: bash >= 4.3 is required for this script" >&2
  exit 1
fi

set -euo pipefail

libBIDSsh_csv_filter() {
  # libBIDSsh_filter
  # function to filter csv-structured BIDS data, returning specified columns and optionally filtering by row content
  # Uses awk to perform filtering, see `man grep` for details on extended regex specification
  # All filtering are combined with AND
  # Usage:
  # libBIDSsh_csv_filter "${csv_data}" [-c column,column...] [-r filter] .. [-r filter] [-d column,column...]
  #   -c, --columns <list>           Comma-separated list of column indices or column names
  #   -r, --row-filter <col:pattern> Subset rows where column matches exact string or regex pattern
  #   -d, --drop-na <list>           Comma-separated list of columns to check for NA values (drops rows where any specified column equals "NA")
  local csv_data="$1"
  shift

  local columns=""
  local row_filters=()
  local drop_na_cols=""

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -c | --columns)
      columns="$2"
      shift 2
      ;;
    -r | --row-filter)
      row_filters+=("$2")
      shift 2
      ;;
    -d | --drop-na)
      drop_na_cols="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      return 1
      ;;
    esac
  done

  # Convert row filters array to a delimiter-separated string that awk can parse
  local row_filters_str=$(printf "%s\n" "${row_filters[@]}" | awk '{gsub(/:/, "\t"); print}' | paste -sd "\n" -)

  awk -v columns="${columns}" \
    -v row_filters_str="${row_filters_str}" \
    -v drop_na_cols="${drop_na_cols}" \
    'BEGIN {
            FS=","; OFS=",";
            split(columns, cols, ",");
            split(drop_na_cols, na_cols, ",");

            # Parse row filters
            filter_count = split(row_filters_str, filter_lines, "\n");
            for (i = 1; i <= filter_count; i++) {
                split(filter_lines[i], filter_parts, "\t");
                if (length(filter_parts) >= 2) {
                    filters[i]["col"] = filter_parts[1];
                    filters[i]["pattern"] = filter_parts[2];
                }
            }
        }
        NR == 1 {
            # Process header
            for (i = 1; i <= NF; i++) {
                colnames[$i] = i;
            }

            # Determine columns to keep
            if (columns != "") {
                delete outcols;
                outcount = 0;
                for (i in cols) {
                    if (cols[i] in colnames) {
                        # Column name provided
                        outcols[++outcount] = colnames[cols[i]];
                    } else if (cols[i] ~ /^[0-9]+$/) {
                        # Column index provided
                        outcols[++outcount] = cols[i];
                    }
                }

                # Print selected columns from header
                for (i = 1; i <= outcount; i++) {
                    printf "%s%s", $outcols[i], (i < outcount ? OFS : ORS);
                }
            } else {
                # Print all columns if none specified
                print;
            }
            next;
        }
        {
            # Check all row filters if specified (combined with AND)
            if (filter_count > 0) {
                for (i = 1; i <= filter_count; i++) {
                    # Determine column for filtering
                    if (filters[i]["col"] in colnames) {
                        col = colnames[filters[i]["col"]];
                    } else if (filters[i]["col"] ~ /^[0-9]+$/) {
                        col = filters[i]["col"];
                    } else {
                        exit 1;
                    }

                    if ($col !~ filters[i]["pattern"]) next;
                }
            }

            # Check for NA values in specified columns
            if (drop_na_cols != "") {
                for (i in na_cols) {
                    # Determine column to check
                    if (na_cols[i] in colnames) {
                        col = colnames[na_cols[i]];
                    } else if (na_cols[i] ~ /^[0-9]+$/) {
                        col = na_cols[i];
                    } else {
                        exit 1;
                    }

                    if ($col == "NA") next;
                }
            }

            # Print row (selected columns or all)
            if (columns != "") {
                for (i = 1; i <= outcount; i++) {
                    printf "%s%s", $outcols[i], (i < outcount ? OFS : ORS);
                }
            } else {
                print;
            }
        }' <<<"${csv_data}"
}

libBIDSsh_drop_na_columns() {
  local csv_data="$1"
  awk -F, '
    BEGIN {OFS=","}
    NR == 1 {
        # Save header and initialize column tracking
        header = $0
        for (i = 1; i <= NF; i++) {
            col_all_na[i] = 1  # Assume all columns are all NA initially
            header_cols[i] = $i  # Store header names
        }
        next
    }
    {
        for (i = 1; i <= NF; i++) {
            if ($i != "NA") {
                col_all_na[i] = 0  # Mark column as not all NA
            }
        }
        # Store all rows for later printing
        rows[NR] = $0
    }
    END {
        # Determine which columns to keep
        split(header, header_fields, /,/)
        for (i = 1; i <= NF; i++) {
            if (!col_all_na[i]) {
                cols_to_keep[i] = 1
            }
        }

        # Print header (only keeping non-NA columns)
        first_field = 1
        for (i = 1; i <= NF; i++) {
            if (cols_to_keep[i]) {
                if (!first_field) {
                    printf "%s", OFS
                }
                printf "%s", header_fields[i]
                first_field = 0
            }
        }
        printf "\n"

        # Print each row (only keeping non-NA columns)
        for (j = 2; j <= NR; j++) {
            split(rows[j], row_fields, /,/)
            first_field = 1
            for (i = 1; i <= NF; i++) {
                if (cols_to_keep[i]) {
                    if (!first_field) {
                        printf "%s", OFS
                    }
                    printf "%s", row_fields[i]
                    first_field = 0
                }
            }
            printf "\n"
        }
    }' <<<"${csv_data}"
}

_libBIDSsh_parse_filename() {
  # Breakup the BIDS filename components and return a key-value pair array
  # Along with a key ordering array
  # Internal function
  local path="$1"
  local -n arr="$2" # nameref to the associative array

  # Extract the filename without path
  local filename=$(basename "${path}")

  # Initialize the arrays
  arr=()
  local -a key_order=() # To maintain the order of keys

  # Store the full path and filename
  arr[path]=$(tr -s / <<<"${path}")
  arr[extension]="${filename#*.}"
  # Extract from schema
  # jq -r .objects.datatypes.[].value schema.json  | paste -s -d'|'
  arr[data_type]=$(grep -o -E "(anat|beh|dwi|eeg|fmap|func|ieeg|meg|micr|motion|mrs|perf|pet|nirs)" <<<$(dirname ${path}) | head -1 || echo "NA")
  arr[derivatives]=$(grep -o 'derivatives/.*/' <<<"${path}" | awk -F/ '{print $2}' || echo "NA")

  local name_no_ext="${filename%%.*}"

  # Split into parts separated by _
  IFS='_' read -ra parts <<<"${name_no_ext}"

  # Process middle parts which are _<key>-<value>
  for ((i = 0; i < ${#parts[@]} - 1; i++)); do
    local part="${parts[${i}]}"
    if [[ ${part} =~ ^([^-]+)-(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # Store the key-value pair
      arr["${key}"]="${key}-${value}"
      # Record the order of the key
      key_order+=("${key}")
    fi
  done

  arr[suffix]="${parts[-1]}"

  key_order+=("suffix")
  key_order+=("extension")
  key_order+=("data_type")
  key_order+=("derivatives")
  key_order+=("path")

  # Store the key order in the array
  arr[_key_order]="${key_order[*]}"
}

libBIDSsh_extension_json_rows_to_column_json_path() {
  local csv_data="$1"

  awk -F',' '
  BEGIN {
    OFS = ",";
  }

  NR == 1 {
    # Capture header, get column indexes
    for (i = 1; i <= NF; i++) {
      col = tolower($i);
      header_map[col] = i;
      headers[i] = $i;
    }

    ext_idx  = header_map["extension"];
    path_idx = header_map["path"];

    if (!ext_idx || !path_idx) {
      print "Error: Required columns (extension, path) not found" > "/dev/stderr";
      exit 1;
    }

    print $0, "json_path";  # add json_path column
    next;
  }

  {
    row[NR] = $0;
    extension = $ext_idx;
    path = $path_idx;

    # Construct key by all fields except extension and path
    key = "";
    for (i = 1; i <= NF; i++) {
      if (i != ext_idx && i != path_idx) key = key "|" $i;
    }

    row_key[NR] = key;
    row_ext[NR] = extension;
    row_path[NR] = path;

    if (tolower(extension) == "json") {
      json_path[key] = path;
      json_row[NR] = 1;
    } else {
      has_non_json[key] = 1;
    }

    line_nums[NR] = 1;
  }

  END {
    for (ln = 2; ln <= NR; ln++) {
      key = row_key[ln];
      is_json = (ln in json_row);
      has_match = (key in has_non_json);

      if (is_json && has_match) {
        # Drop matched json row
        continue;
      }

      if (is_json && !has_match) {
        print row[ln], row_path[ln];  # unmatched json
      } else if (!is_json && (key in json_path)) {
        print row[ln], json_path[key];  # matched non-json
      } else {
        print row[ln], "NA";  # no json available
      }
    }
  }
  ' <<<"$csv_data"
}

libBIDSsh_parse_bids_to_csv() {

  local bidspath=$1

  # Build the pattern piece by piece
  local base_pattern="*"

  # Entities components
  # Extracted from schema with generate_entity_patterns.sh
  local entities=(
    "*(_sub-+([a-zA-Z0-9]))"
    "*(_ses-+([a-zA-Z0-9]))"
    "*(_sample-+([a-zA-Z0-9]))"
    "*(_task-+([a-zA-Z0-9]))"
    "*(_tracksys-+([a-zA-Z0-9]))"
    "*(_acq-+([a-zA-Z0-9]))"
    "*(_nuc-+([a-zA-Z0-9]))"
    "*(_voi-+([a-zA-Z0-9]))"
    "*(_ce-+([a-zA-Z0-9]))"
    "*(_trc-+([a-zA-Z0-9]))"
    "*(_stain-+([a-zA-Z0-9]))"
    "*(_rec-+([a-zA-Z0-9]))"
    "*(_dir-+([a-zA-Z0-9]))"
    "*(_run-+([0-9]))"
    "*(_mod-+([a-zA-Z0-9]))"
    "*(_echo-+([0-9]))"
    "*(_flip-+([0-9]))"
    "*(_inv-+([0-9]))"
    "*(_mt-+([a-zA-Z0-9]))"
    "*(_part-+([a-zA-Z0-9]))"
    "*(_proc-+([a-zA-Z0-9]))"
    "*(_hemi-+([a-zA-Z0-9]))"
    "*(_space-+([a-zA-Z0-9]))"
    "*(_split-+([0-9]))"
    "*(_recording-+([a-zA-Z0-9]))"
    "*(_chunk-+([0-9]))"
    "*(_seg-+([a-zA-Z0-9]))"
    "*(_res-+([a-zA-Z0-9]))"
    "*(_den-+([a-zA-Z0-9]))"
    "*(_label-+([a-zA-Z0-9]))"
    "*(_desc-+([a-zA-Z0-9]))"
  )

  # Suffixes from schema.json
  # jq -r .objects.suffixes.[].value schema.json | paste -s -d'|'
  suffixes+="_@(2PE|BF|Chimap|CARS|CONF|DIC|DF|FLAIR|FLASH|FLUO|IRT1|M0map|MEGRE|MESE|MP2RAGE|MPE|MPM|MTR|MTRmap|MTS|MTVmap|MTsat|MWFmap|NLO|OCT|PC|PD|PDT2|PDmap|PDw|PLI|R1map|R2map|R2starmap|RB1COR|RB1map|S0map|SEM|SPIM|SR|T1map|T1rho|T1w|T2map|T2star|T2starmap|T2starw|T2w|TB1AFI|TB1DAM|TB1EPI|TB1RFM|TB1SRGE|TB1TFL|TB1map|TEM|UNIT1|VFA|angio|asl|aslcontext|asllabeling|beh|blood|bold|cbv|channels|coordsystem|defacemask|descriptions|dseg|dwi|eeg|electrodes|epi|events|fieldmap|headshape|XPCT|ieeg|inplaneT1|inplaneT2|m0scan|magnitude|magnitude1|magnitude2|markers|mask|meg|motion|mrsi|mrsref|nirs|noRF|optodes|pet|phase|phase1|phase2|phasediff|photo|physio|probseg|sbref|scans|sessions|stim|svs|uCT|unloc)"

  # Allowed extensions
  # jq -r .objects.extensions.[].value schema.json | paste -s -d'|'
  # Stripped the ".*" and directory entries manually
  local extensions="@(.ave|.bdf|.bval|.bvec|.chn|.con|.dat|.dlabel.nii|.edf|.eeg|.fdt|.fif|.jpg|.json|.kdf|.label.gii|.md||.mhd|.mrk|.nii|.nii.gz|.nwb|.ome.btf|.ome.tif|.png|.pos|.raw|.rst|.set|.snirf|.sqd|.tif|.trg|.tsv|.tsv.gz|.txt|.vhdr|.vmrk)"

  # Piece together the pattern
  local pattern=${base_pattern}
  for entry in "${entities[@]}"; do
    pattern+=${entry}
  done
  pattern+=${suffixes}
  pattern+=${extensions}

  shopt -s extglob
  shopt -s nullglob
  shopt -s globstar

  local files=("${bidspath}"/**/${pattern})

  shopt -u extglob
  shopt -u nullglob
  shopt -u globstar

  # Order of entities from generate_entity_patterns.sh
  entities_displayname_order="subject,session,sample,task,tracksys,acquisition,nucleus,volume,ceagent,tracer,stain,reconstruction,direction,run,modality,echo,flip,inversion,mtransfer,part,processing,hemisphere,space,split,recording,chunk,segmentation,resolution,density,label,description"
  entities_order="sub ses sample task tracksys acq nuc voi ce trc stain rec dir run mod echo flip inv mt part proc hemi space split recording chunk seg res den label desc"

  echo "derivatives,data_type,${entities_displayname_order},suffix,extension,path"
  for file in "${files[@]}"; do
    declare -A file_info
    _libBIDSsh_parse_filename "${file}" file_info
    for key in derivatives data_type ${entities_order} suffix extension path; do
      if [[ "${file_info[${key}]+abc}" ]]; then
        echo -n "${file_info[${key}]},"
      else
        echo -n NA,
      fi
    done
    echo ""
  done | sed 's/,*$//'
}

libBIDSsh_csv_column_to_array() {
  # function to convert a column from a libBIDSsh csv data structure to an array
  # optionally return only unique entries and/or exclude NA
  # Usage example:
  # declare -a my_array
  # libBIDSsh_csv_column_to_array "${bids_csv_data}" "column_name" my_array [unique] [exclude_NA]

  local csv_data="$1"
  local column="$2"
  local -n array_ref="$3" # nameref to the array variable
  local unique="${4:-true}"
  local exclude_NA="${5:-true}"

  # Clear the array in case it's not empty
  array_ref=()

  # Use awk to extract the column (skipping header row)
  while IFS= read -r line; do
    # Skip NA entries if exclude_NA is true
    if [[ "${exclude_NA}" == "true" && "${line}" == "NA" ]]; then
      continue
    fi
    array_ref+=("${line}")
  done < <(awk -v col="${column}" '
        BEGIN { FS="," }
        NR == 1 {
            if (col ~ /^[0-9]+$/) {
                col_idx = col
            } else {
                for (i = 1; i <= NF; i++) {
                    if ($i == col) {
                        col_idx = i
                        break
                    }
                }
            }
            if (!col_idx) exit 1
            next  # Skip header row
        }
        { print $col_idx }
    ' <<<"${csv_data}")

  # Check if awk succeeded
  if [ ${#array_ref[@]} -eq 0 ] && [ $(wc -l <<<"${csv_data}") -gt 1 ]; then
    echo "Error: Column '${column}' not found or no data rows present" >&2
    return 1
  fi

  # Apply unique filter if requested
  if [[ "${unique}" == "true" ]]; then
    local -a unique_array
    local -A seen
    for item in "${array_ref[@]}"; do
      if [[ -z "${seen[${item}]+x}" ]]; then
        unique_array+=("${item}")
        seen["${item}"]=1
      fi
    done
    array_ref=("${unique_array[@]}")
  fi
}

libBIDS_csv_iterator() {
  # function which takes in libBIDS.sh CSV and returns one row as key-value pairs
  # optionally sorting the CSV first according to one or more columns
  # do not change sorting between calls, only basic line-number state is kept
  # libBIDS_csv_iterator "${csv_data}" row_data [sort_column_name] ... [sort_column_name]
  # Usage example:
  # declare -A row_data
  # while libBIDS_csv_iterator "${csv_data}" row_data [sorting_column]; do
  #   declare -p row_data #Show the contents of row_data key-value pairs
  # done
  # Options:
  #   -r : reverse the sort order

  local csv_var=$1    # Name of the variable containing CSV data
  local -n arr_ref=$2 # Name reference to the associative array
  shift 2             # Remaining arguments are sort columns or options

  # Handle options
  local reverse_sort=false
  local sort_columns=()
  for arg in "$@"; do
    if [[ "$arg" == "-r" ]]; then
      reverse_sort=true
    else
      sort_columns+=("$arg")
    fi
  done

  # Read all lines into an array
  IFS=$'\n' read -d '' -r -a lines <<<"${csv_var}" || true

  # Handle empty input
  if [[ ${#lines[@]} -eq 0 ]]; then
    arr_ref=()
    return 1
  fi

  # Extract header and data lines
  local header="${lines[0]}"
  local data_lines=("${lines[@]:1}")

  # If we have sort columns, sort the data
  if ((${#sort_columns[@]} > 0)); then
    # Get column indices for sorting
    IFS=',' read -r -a headers <<<"${header}"
    declare -A column_indices
    for i in "${!headers[@]}"; do
      column_indices["${headers[i]}"]=${i}
    done

    # Build sort keys (-k options for sort)
    local sort_keys=()
    for col in "${sort_columns[@]}"; do
      if [[ -v "column_indices[${col}]" ]]; then
        local idx=$((column_indices["${col}"] + 1)) # sort uses 1-based indexing
        sort_keys+=("-k$idx,$idx")
      else
        echo "Error: Column '${col}' not found in CSV header" >&2
        return 1
      fi
    done

    # Add reverse flag if needed
    local sort_reverse_flag=()
    if [[ "$reverse_sort" == true ]]; then
      sort_reverse_flag=("-r")
    fi

    # Sort the data lines (handle empty case)
    if [[ ${#data_lines[@]} -gt 0 ]]; then
      IFS=$'\n' sorted_data=($(
        printf "%s\n" "${data_lines[@]}" |
          sort --version-sort -t, "${sort_reverse_flag[@]}" "${sort_keys[@]}"
      )) || true
    else
      sorted_data=()
    fi
  else
    # No specific sort columns provided, sort by all columns left to right
    IFS=',' read -r -a headers <<<"${header}"
    local sort_keys=()
    for i in "${!headers[@]}"; do
      local idx=$((i + 1)) # sort uses 1-based indexing
      sort_keys+=("-k$idx,$idx")
    done

    # Add reverse flag if needed
    local sort_reverse_flag=()
    if [[ "$reverse_sort" == true ]]; then
      sort_reverse_flag=("-r")
    fi

    # Sort the data lines (handle empty case)
    if [[ ${#data_lines[@]} -gt 0 ]]; then
      IFS=$'\n' sorted_data=($(
        printf "%s\n" "${data_lines[@]}" |
          sort --version-sort -t, "${sort_reverse_flag[@]}" "${sort_keys[@]}"
      )) || true
    else
      sorted_data=()
    fi
  fi

  # Use a line counter local to this function call
  local current_line=${arr_ref[__current_line]:-0}

  # If we're at the end or have no data, return failure
  if ((current_line >= ${#sorted_data[@]} + 1)) || [[ ${#sorted_data[@]} -eq 0 ]]; then
    # Clear the array before returning
    arr_ref=()
    return 1
  fi

  # Clear the array completely (no state maintained between calls)
  arr_ref=()

  # Process header if we're on the first line
  if ((current_line == 0)); then
    IFS=',' read -r -a headers <<<"${header}"
    ((current_line++))
  fi

  # Read the current data line (with bounds checking)
  if ((current_line > 0 && current_line <= ${#sorted_data[@]})); then
    local line_content="${sorted_data[current_line - 1]}"
    IFS=',' read -r -a values <<<"${line_content}"

    # Store key-value pairs in the array
    for i in "${!headers[@]}"; do
      if [[ -v "values[i]" ]]; then
        arr_ref["${headers[i]}"]="${values[i]}"
      else
        arr_ref["${headers[i]}"]=""
      fi
    done
  fi

  # Update the line counter for next time (stored in array, but cleared next call)
  ((current_line++))
  arr_ref[__current_line]=${current_line}

  return 0
}

libBIDSsh_json_to_associative_array() {
  local json_file="$1"
  declare -n arr_ref="$2" # nameref to the associative array

  # Use jq to process the JSON file and output key-value pairs with type prefixes
  while IFS="=" read -r key value; do
    # Remove quotes from key (jq outputs keys with quotes)
    key="${key%\"}"
    key="${key#\"}"
    arr_ref["$key"]="$value"
  done < <(jq -r 'to_entries[] |
        "\(.key)=\(
            if .value|type == "array" then "array:" + (.value|join(","))
            elif .value|type == "object" then "object:" + (.value|tostring)
            else (.value|type) + ":" + (.value|tostring)
            end
        )"' "$json_file")
}

# bash "if __main__" implementation
if ! (return 0 2>/dev/null); then
  if [[ $# -eq 0 ]]; then
    echo 'error: the first argument must be a path to a bids dataset'
    exit 1
  fi
  libBIDSsh_parse_bids_to_csv "${1}"
fi
