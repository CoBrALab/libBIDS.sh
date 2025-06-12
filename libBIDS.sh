#!/usr/bin/env bash

[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || (echo "Error: bash >= 4.0 is required for this script" >&2 && exit 1)

set -euo pipefail

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
  suffixes+="|magnitude1|magnitude2|phasediff|phase1|phase2|fieldmap|magnitude|epi)"

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
  done
}

# bash "if __main__" implementation
if ! (return 0 2>/dev/null); then
  if [[ $# -eq 0 ]] ; then
      echo 'error: the first argument must be a path to a bids dataset'
      exit 1
  fi
  libBIDSsh_parse_bids $1
fi
