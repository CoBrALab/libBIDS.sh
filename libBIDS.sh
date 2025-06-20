#!/usr/bin/env bash

[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || (echo "Error: bash >= 4.0 is required for this script" >&2 && exit 1)

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
  arr[filename]="${filename}"
  arr[extension]="${filename#*.}"
  arr[type]=$(grep -E -o '(func|dwi|fmap|anat|perf|meg|eeg|ieeg|beh|pet|micr|nirs|motion|mrs)' <<<$(basename $(dirname "${path}")) || echo "NA")
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
  key_order+=("type")
  key_order+=("derivatives")
  key_order+=("path")
  key_order+=("filename")

  # Store the key order in the array
  arr[_key_order]="${key_order[*]}"

}

libBIDSsh_parse_bids_to_csv() {

  local bidspath=$1

  # Build the pattern piece by piece
  local base_pattern="*"

  # Optional components
  local optional_components=(
    "*(_ses-+([a-zA-Z0-9]))"          # _ses-<label>
    "*(_task-+([a-zA-Z0-9]))"         # _task-<label>
    "*(_acq-+([a-zA-Z0-9]))"          # _acq-<label>
    "*(_ce-+([a-zA-Z0-9]))"           # _ce-<label>
    "*(_rec-+([a-zA-Z0-9]))"          # _rec-<label>
    "*(_dir-+([a-zA-Z0-9]))"          # _dir-<label>
    "*(_run-+([0-9]))"                # _run-<index>
    "*(_recording-+([a-zA-Z0-9]))"    # _recording-<label>
    "*(_mod-+([a-zA-Z0-9]))"          # _mod-<label>
    "*(_echo-+([0-9]))"               # _echo-<index>
    "*(_part-@(mag|phase|real|imag))" # _part-<mag|phase|real|imag>
    "*(_chunk-+([0-9]))"              # _chunk-<index>
  )

  # Anatomical suffixes
  # UNIT1 suffix is technically incorrect as it cannot coexist with the _part-@(mag|phase|real|imag)
  local suffixes="_@(FLAIR|PDT2|PDw|T1w|T2starw|T2w|UNIT1|angio|inplaneT1|inplaneT2"
  # Parametric map suffixes
  suffixes+="|Chimap|M0map|MTRmap|MTVmap|MTsat|MWFmap|PDmap|R1map|R2map|R2starmap|RB1map|S0map|T1map|T1rho|T2map|T2starmap|TB1map"
  # Defacing mask
  suffixes+="|defacemask"
  # Depreciated anatomical suffixes
  # FLASH PD and T2star are depreciated but we support them
  suffixes+="|FLASH|PD|T2star"
  # Functional images
  suffixes+="|bold|cbv|phase|sbref|noRF|events|physio|stim"
  # Diffusion images
  suffixes+="|dwi|sbref"
  # Perfusion images
  suffixes+="|asl|m0scan|aslcontext|noRF"
  # Field maps
  suffixes+="|magnitude1|magnitude2|phasediff|phase1|phase2|fieldmap|magnitude|epi"
  # Modality agnostic files
  suffixes+="|scans|sessions)"

  # Allowed extensions
  local extensions="@(.nii|.json|.tsv|bval|bvec)?(.gz)"

  # Piece together the pattern
  local pattern=${base_pattern}
  for entry in "${optional_components[@]}"; do
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

  echo "sub,ses,task,acq,ce,rec,dir,run,recording,mod,echo,part,chunk,suffix,extension,type,derivatives,filename,path"
  for file in "${files[@]}"; do
    declare -A file_info
    _libBIDSsh_parse_filename "${file}" file_info
    for key in sub ses task acq ce rec dir run recording mod echo part chunk suffix extension type derivatives filename path; do
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

  local csv_var=$1    # Name of the variable containing CSV data
  local -n arr_ref=$2 # Name reference to the associative array
  shift 2             # Remaining arguments are sort columns

  # Store sort columns
  local sort_columns=("$@")

  # Read all lines into an array
  IFS=$'\n' read -d '' -r -a lines <<<"${csv_var}" || true

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

    # Sort the data lines
    IFS=$'\n' sorted_data=($(
      printf "%s\n" "${data_lines[@]}" |
        sort --version-sort -t, "${sort_keys[@]}"
    )) || true
  else
    # No sorting needed
    sorted_data=("${data_lines[@]}")
  fi

  # Use a line counter local to this function call
  local current_line=${arr_ref[__current_line]:-0}

  # If we're at the end, return failure (for while loop exit)
  if ((current_line >= ${#sorted_data[@]} + 1)); then # +1 for header
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

  # Read the current data line (note we use sorted_data which is 0-based)
  if ((current_line > 0 && current_line <= ${#sorted_data[@]} + 1)); then
    IFS=',' read -r -a values <<<"${sorted_data[current_line - 1]}"

    # Store key-value pairs in the array
    for i in "${!headers[@]}"; do
      arr_ref["${headers[i]}"]="${values[i]}"
    done
  fi

  # Update the line counter for next time (stored in array, but cleared next call)
  ((current_line++))
  arr_ref[__current_line]=${current_line}

  return 0
}

# bash "if __main__" implementation
if ! (return 0 2>/dev/null); then
  if [[ $# -eq 0 ]]; then
    echo 'error: the first argument must be a path to a bids dataset'
    exit 1
  fi
  libBIDSsh_parse_bids_to_csv "${1}"
fi
