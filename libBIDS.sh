#!/usr/bin/env bash

[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || (echo "Error: bash >= 4.0 is required for this script" >&2 && exit 1)

set -euo pipefail

libBIDSsh_filter() {
  # libBIDSsh_filter
  # function to filter csv-structured BIDS data, returning specified columns and optionally filtering by row content
  # Uses awk to perform filtering, see `man grep` for details on extended regex specification
  # All filtering are combined with AND
  #   -c, --columns <list>           Comma-separated list of column indices or column names
  #   -R, --row-filter <col:pattern> Subset rows where column matches exact string or regex pattern
  local csv_data="$1"
  shift

  local columns=""
  local row_filter=""

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -c | --columns)
      columns="$2"
      shift 2
      ;;
    -R | --row-filter)
      row_filter="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      return 1
      ;;
    esac
  done

  awk -v columns="$columns" \
    -v row_filter="$row_filter" \
    'BEGIN {
            FS=","; OFS=",";
            split(columns, cols, ",");
            split(row_filter, filter_arr, ":");
            filter_col = filter_arr[1];
            filter_pattern = filter_arr[2];
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
            # Check row filter if specified
            if (row_filter != "") {
                # Determine column for filtering
                if (filter_col in colnames) {
                    col = colnames[filter_col];
                } else if (filter_col ~ /^[0-9]+$/) {
                    col = filter_col;
                } else {
                    exit 1;
                }

                if ($col !~ filter_pattern) next;
            }

            # Print row (selected columns or all)
            if (columns != "") {
                for (i = 1; i <= outcount; i++) {
                    printf "%s%s", $outcols[i], (i < outcount ? OFS : ORS);
                }
            } else {
                print;
            }
        }' <<<"$csv_data"
}

_libBIDSsh_parse_filename() {
  # Breakup the BIDS filename components and return a key-value pair array
  # Along with a key ordering array
  local path="$1"
  local -n arr="$2" # nameref to the associative array

  # Extract the filename without path
  local filename=$(basename "${path}")

  # Initialize the arrays
  arr=()
  local -a key_order=() # To maintain the order of keys

  # Store the full path and filename
  arr[path]="${path}"
  arr[filename]="${filename}"
  arr[extension]="${filename#*.}"
  arr[type]="$(basename $(dirname ${path}))"

  local name_no_ext="${filename%%.*}"

  # Split into parts separated by _
  IFS='_' read -ra parts <<<"${name_no_ext}"

  # Subject
  arr[sub]="${parts[0]}"
  key_order+=("sub")

  # Process middle parts which are _<key>-<value>
  for ((i = 1; i < ${#parts[@]} - 1; i++)); do
    local part="${parts[$i]}"
    if [[ ${part} =~ ^([^-]+)-(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # Store the key-value pair
      arr["$key"]="${key}-${value}"
      # Record the order of the key
      key_order+=("${key}")
    fi
  done

  arr[suffix]="${parts[-1]}"

  key_order+=("suffix")
  key_order+=("extension")
  key_order+=("type")
  key_order+=("path")
  key_order+=("filename")

  # Store the key order in the array
  arr[_key_order]="${key_order[*]}"

}

function libBIDSsh_parse_bids() {

  local bidspath=$1

  # Build the pattern piece by piece
  # Subject pattern
  local base_pattern="sub-+([a-zA-Z0-9])" # sub-<label>

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
  for entry in ${optional_components[@]}; do
    pattern+=${entry}
  done
  pattern+=${suffixes}
  pattern+=${extensions}

  shopt -s extglob
  shopt -s nullglob
  shopt -s globstar

  local files=(${bidspath}/sub-*/**/${pattern})

  shopt -u extglob
  shopt -u nullglob
  shopt -u globstar

  echo "sub,ses,task,acq,ce,rec,dir,run,recording,mod,echo,part,chunk,suffix,extension,type,filename,path"
  for file in ${files[@]}; do
    declare -A file_info
    _libBIDSsh_parse_filename "${file}" file_info
    for key in sub ses task acq ce rec dir run recording mod echo part chunk suffix extension type filename path; do
      if [[ "${file_info[${key}]+abc}" ]]; then
        echo -n "${file_info[${key}]},"
      else
        echo -n NA,
      fi
    done
    echo ""
  done | sed 's/,*$//'
}

# bash "if __main__" implementation
if ! (return 0 2>/dev/null); then
  if [[ $# -eq 0 ]] ; then
      echo 'error: the first argument must be a path to a bids dataset'
      exit 1
  fi
  libBIDSsh_parse_bids $1
fi
