#!/usr/bin/env bash

set -euo pipefail

# Avoid matching current dir during glob tests if it isn't expected
shopt -u nullglob

# Resolve paths from the directory of this script, not from the CWD.
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bids_examples="${test_dir}/bids-examples"

# shellcheck disable=SC1091
source "${test_dir}/libBIDS.sh"

# All fixtures go below this directory; it is removed on exit.
test_tmpdir="$(mktemp -d)"
trap 'rm -rf "${test_tmpdir}"' EXIT

# The example datasets come from the bids-examples git submodule.
if [[ ! -d "${bids_examples}/ds001" ]]; then
  echo "Error: ${bids_examples} is missing. Run: git submodule update --init" >&2
  exit 1
fi

# Simple test runner
tests_run=0
tests_passed=0
tests_failed=0
tests_skipped=0

# Exit status a test uses to report a skip (see skip_test).
readonly SKIP_STATUS=77

run_test() {
  # Run one test function and record PASS, FAIL or SKIP.
  # The test runs in a subshell with errexit on and outside of any
  # conditional context ("if", "||", ...). Thus a failed command fails the
  # test. An assertion that fails also fails the test, even when its status
  # is not checked, because assert_* set _assertion_failed.
  local name="$1"
  local func="$2"
  local rc=0

  tests_run=$((tests_run + 1))
  echo "Running $name..."
  set +e
  (
    set -e
    _assertion_failed=0
    "$func"
    ((_assertion_failed == 0))
  )
  rc=$?
  set -e

  if ((rc == 0)); then
    echo "  [PASS]"
    tests_passed=$((tests_passed + 1))
  elif ((rc == SKIP_STATUS)); then
    echo "  [SKIP]"
    tests_skipped=$((tests_skipped + 1))
  else
    echo "  [FAIL]"
    tests_failed=$((tests_failed + 1))
  fi
}

skip_test() {
  # Stop the current test and report it as skipped.
  # Usage: skip_test "reason"
  echo "    Skip: $1"
  exit "${SKIP_STATUS}"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-}"

  if [[ "$expected" != "$actual" ]]; then
    echo "    Assertion failed: $msg"
    echo "      Expected: '$expected'"
    echo "      Actual:   '$actual'"
    _assertion_failed=1
    return 1
  fi
  return 0
}

assert_contains() {
  local substring="$1"
  local string="$2"
  local msg="${3:-}"

  if [[ "$string" != *"$substring"* ]]; then
    echo "    Assertion failed: $msg"
    echo "      Expected to contain: '$substring'"
    echo "      Actual string:       '${string:0:200}...'"
    _assertion_failed=1
    return 1
  fi
  return 0
}

test_parse_filename() {
  local file="sub-01_ses-test_task-fingerfootlips_run-1_bold.nii.gz"
  declare -A file_info
  _libBIDSsh_parse_filename "$file" file_info

  assert_equals "sub-01" "${file_info[sub]:-}" "subject should be sub-01" || return 1
  assert_equals "ses-test" "${file_info[ses]:-}" "session should be ses-test" || return 1
  assert_equals "task-fingerfootlips" "${file_info[task]:-}" "task should be task-fingerfootlips" || return 1
  assert_equals "run-1" "${file_info[run]:-}" "run should be run-1" || return 1
  assert_equals "bold" "${file_info[suffix]:-}" "suffix should be bold" || return 1
  assert_equals "nii.gz" "${file_info[extension]:-}" "extension should be nii.gz" || return 1
  return 0
}

test_parse_filename_datatype_derivatives() {
  # Datatype must come from the file's parent directory anchored to a whole
  # path component, not a substring anywhere in the path.
  declare -A a
  _libBIDSsh_parse_filename "/data/study_func_proj/sub-01/anat/sub-01_T1w.nii.gz" a
  assert_equals "anat" "${a[datatype]:-}" "datatype must be anat despite 'func' in path" || return 1

  declare -A b
  _libBIDSsh_parse_filename "/data/sub-01/emg/sub-01_task-rest_emg.edf" b
  assert_equals "emg" "${b[datatype]:-}" "emg datatype should be detected" || return 1

  # No datatype directory -> NA
  declare -A c
  _libBIDSsh_parse_filename "/data/sub-01/sub-01_scans.tsv" c
  assert_equals "NA" "${c[datatype]:-}" "missing datatype dir should be NA" || return 1

  # Derivatives pipeline is the component right after 'derivatives/'.
  declare -A d
  _libBIDSsh_parse_filename "/data/derivatives/fmriprep/sub-01/anat/sub-01_desc-preproc_T1w.nii.gz" d
  assert_equals "fmriprep" "${d[derivatives]:-}" "derivatives pipeline should be fmriprep" || return 1
  assert_equals "anat" "${d[datatype]:-}" "derivative datatype should be anat" || return 1

  # A directory merely containing the word 'derivatives' must not match.
  declare -A e
  _libBIDSsh_parse_filename "/data/myderivatives/sub-01/anat/sub-01_T1w.nii.gz" e
  assert_equals "NA" "${e[derivatives]:-}" "'myderivatives' must not be treated as derivatives" || return 1

  return 0
}

test_parse_bids_to_table() {
  local bids_dir="${bids_examples}/ds001"
  local table
  table=$(libBIDSsh_parse_bids_to_table "$bids_dir")

  assert_contains "sub-01" "$table" "table should contain sub-01" || return 1
  assert_contains "task-balloonanalogrisktask" "$table" "table should contain task-balloonanalogrisktask" || return 1

  # Check header
  local header
  header=$(head -n 1 <<<"$table")
  # Columns use entity names (subject), not entity keys (sub).
  local fields=$'\t'"${header}"$'\t'
  assert_equals "derivatives	datatype	subject" "$(cut -f 1-3 <<<"$header")" \
    "header should start with derivatives, datatype, subject" || return 1
  assert_contains $'\tsession\t' "$fields" "header should contain session" || return 1
  assert_contains $'\ttask\t' "$fields" "header should contain task" || return 1
  assert_equals "suffix	extension	path" \
    "$(awk -F '\t' -v OFS='\t' '{ print $(NF - 2), $(NF - 1), $NF }' <<<"$header")" \
    "header should end with suffix, extension, path" || return 1
  if [[ "$fields" == *$'\tsub\t'* || "$fields" == *$'\tses\t'* ]]; then
    echo "    Assertion failed: header must not use entity keys sub/ses"
    return 1
  fi

  # Verify size roughly (this is a known dataset)
  local row_count
  row_count=$(wc -l <<<"$table")
  if ((row_count < 10)); then
    echo "    Assertion failed: dataset parsed seems too small ($row_count rows)"
    return 1
  fi
  return 0
}
# shellcheck disable=SC2016  # $1 and $2 expand in the child shell.
_custom_header() {
  # Source a library copy in a new shell, parse a dataset and print the
  # header columns that match "acq" or "body", one per line.
  # Usage: _custom_header <libBIDS.sh> <dataset> [cd_dir]
  (
    if [[ -n "${3:-}" ]]; then
      cd "$3"
    fi
    "${BASH}" -c 'source "$1" && libBIDSsh_parse_bids_to_table "$2"' _ "$1" "$2" |
      head -n 1 | tr '\t' '\n' | grep -e acq -e body || true
  )
}

# shellcheck disable=SC2016  # $1 and $2 expand in the child shell.
test_load_custom_entities() {
  if ! command -v jq >/dev/null 2>&1; then
    skip_test "jq not found"
  fi
  local root
  root=$(mktemp -d "${test_tmpdir}/custom.XXXXXX")
  mkdir -p "${root}/lib/custom" "${root}/link" "${root}/ds/sub-01/anat"
  cp "${test_dir}/libBIDS.sh" "${root}/lib/libBIDS.sh"
  touch "${root}/ds/sub-01/anat/sub-01_acq-x_bp-chest_T1w.nii.gz"
  local lib="${root}/lib/libBIDS.sh"
  local cfg="${root}/lib/custom/a.json"
  local out err rc

  # A key that is the same as a standard key or an earlier custom key, and a
  # name that is the same as a standard column, are skipped with a warning.
  printf '%s' '{"entities":[{"key":"bp","name":"bodypart","pattern":"p"},
    {"key":"bp","name":"bodypart2","pattern":"x"},
    {"key":"acq","name":"acquisition","pattern":"y"},
    {"key":"zz","name":"acquisition"}]}' >"$cfg"
  out=$(_custom_header "$lib" "${root}/ds" 2>/dev/null)
  assert_equals $'acquisition\nbodypart' "$out" \
    "duplicate custom keys/names must not add columns" || return 1
  err=$("${BASH}" -c 'source "$1" && libBIDSsh_parse_bids_to_table "$2"' \
    _ "$lib" "${root}/ds" 2>&1 >/dev/null)
  assert_contains "Warning: skipping custom entity key 'bp'" "$err" \
    "duplicate custom key must warn" || return 1
  assert_contains "Warning: skipping custom entity key 'acq'" "$err" \
    "custom key equal to a standard key must warn" || return 1
  assert_contains "Warning: skipping custom entity name 'acquisition'" "$err" \
    "custom name equal to a standard column must warn" || return 1

  # A ';' in a name is kept, and 'pattern' is optional.
  printf '%s' '{"entities":[{"key":"bp","name":"body;part"}]}' >"$cfg"
  out=$(_custom_header "$lib" "${root}/ds")
  assert_equals $'acquisition\nbody;part' "$out" \
    "';' in a custom name must be kept" || return 1

  # Malformed JSON is an error that names the file.
  printf '%s' '{"entities":[{"key":"bp","name":"bodypart"},]}' >"$cfg"
  rc=0
  err=$("${BASH}" -c 'source "$1" && libBIDSsh_parse_bids_to_table "$2"' \
    _ "$lib" "${root}/ds" 2>&1 >/dev/null) || rc=$?
  assert_equals "1" "$rc" "malformed custom JSON must return 1" || return 1
  assert_contains "invalid custom entity file '${cfg}'" "$err" \
    "malformed custom JSON must name the file" || return 1

  # custom/ is found next to the real file when sourced through a symlink,
  # and when CDPATH is set.
  printf '%s' '{"entities":[{"key":"bp","name":"bodypart","pattern":"p"}]}' >"$cfg"
  ln -s "$lib" "${root}/link/libBIDS.sh"
  out=$(_custom_header "${root}/link/libBIDS.sh" "${root}/ds")
  assert_equals $'acquisition\nbodypart' "$out" \
    "custom/ must be found through a symlinked libBIDS.sh" || return 1
  out=$(CDPATH=. _custom_header lib/libBIDS.sh ds "$root")
  assert_equals $'acquisition\nbodypart' "$out" \
    "custom/ must be found when CDPATH is set" || return 1

  # The loader must not change the caller's variables.
  out=$(
    "${BASH}" -c 'key=K name=N pattern=P json_file=J
      source "$1" && libBIDSsh_parse_bids_to_table "$2" >/dev/null
      echo "${key} ${name} ${pattern} ${json_file}"' _ "$lib" "${root}/ds"
  )
  assert_equals "K N P J" "$out" \
    "loader with custom files must not change caller variables" || return 1
  return 0
}

test_parse_bids_to_table_without_jq() {
  # The core parser must work when jq is not installed and no
  # custom/*.json file exists.
  shopt -s nullglob
  local custom_files=("${test_dir}"/custom/*.json)
  shopt -u nullglob
  if ((${#custom_files[@]} > 0)); then
    skip_test "custom/*.json exists, thus the parser needs jq"
  fi

  # Make a PATH with all commands of the current PATH, but not jq.
  local nojq_bin
  nojq_bin=$(mktemp -d "${test_tmpdir}/nojq.XXXXXX")
  local dir
  local cmd
  local -a path_dirs
  IFS=: read -r -a path_dirs <<<"$PATH"
  for dir in ${path_dirs[@]+"${path_dirs[@]}"}; do
    [[ -d "$dir" ]] || continue
    for cmd in "$dir"/*; do
      [[ -x "$cmd" && ! -d "$cmd" ]] || continue
      [[ "${cmd##*/}" == "jq" ]] && continue
      [[ -e "${nojq_bin}/${cmd##*/}" ]] && continue
      ln -s "$cmd" "${nojq_bin}/${cmd##*/}"
    done
  done

  # Do not use "|| rc=$?" here: it would turn off errexit in the
  # command substitution and hide a failed command in the parser.
  local table
  local rc
  local err_file="${nojq_bin}.stderr"
  set +e
  table=$(
    set -e
    exec 2>"$err_file"
    PATH="$nojq_bin"
    hash -r
    if command -v jq >/dev/null 2>&1; then
      echo "jq is still in PATH" >&2
      exit 2
    fi
    libBIDSsh_parse_bids_to_table "${bids_examples}/ds001"
  )
  rc=$?
  set -e

  assert_equals "0" "$rc" "parser should succeed without jq" || return 1
  assert_equals "" "$(<"$err_file")" "parser should write nothing to stderr" || return 1
  assert_equals "derivatives	datatype	subject" "$(head -n 1 <<<"$table" | cut -f 1-3)" \
    "header should start with derivatives, datatype, subject" || return 1
  assert_contains "sub-01" "$table" "table should contain sub-01" || return 1
  # Without jq, the parser must give the same table as with jq.
  local table_with_jq
  table_with_jq=$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds001")
  assert_equals "$table_with_jq" "$table" \
    "ds001 table without jq should be the same as with jq" || return 1
  return 0
}

test_parse_bids_to_table_func_gii() {
  # GIFTI functional files (.func.gii) are in the BIDS schema extension list
  # (schema 2.0.0 / BIDS 1.11.2 and later). The parser must list them.
  local root="${test_tmpdir}/func_gii"
  mkdir -p "${root}/sub-01/func" "${root}/derivatives/prep/sub-01/func"
  touch "${root}/sub-01/func/sub-01_task-a_bold.nii.gz"
  touch "${root}/derivatives/prep/sub-01/func/sub-01_task-a_hemi-L_space-fsaverage_bold.func.gii"

  local table
  table=$(libBIDSsh_parse_bids_to_table "$root")

  assert_equals "3" "$(wc -l <<<"$table" | tr -d ' ')" \
    "table should have a header, the .nii.gz row and the .func.gii row" || return 1

  local gii_row
  gii_row=$(awk -F '\t' -v OFS='\t' '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $col["extension"] == "func.gii" {
      print $col["derivatives"], $col["hemisphere"], $col["space"], $col["suffix"]
    }' <<<"$table")
  assert_equals "prep	hemi-L	space-fsaverage	bold" "$gii_row" \
    ".func.gii row should have derivatives, hemisphere, space and suffix" || return 1

  # Real data: ds000001-fmriprep has .func.gii files. Its .bidsignore
  # excludes '*_bold.func.gii', thus parse it with --no-bidsignore.
  table=$(libBIDSsh_parse_bids_to_table --no-bidsignore "${bids_examples}/ds000001-fmriprep")
  gii_row=$(awk -F '\t' -v OFS='\t' '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $col["path"] ~ /sub-11_task-balloonanalogrisktask_run-1_space-fsaverage5_hemi-L_bold\.func\.gii$/ {
      print $col["subject"], $col["task"], $col["run"], $col["hemisphere"],
        $col["space"], $col["suffix"], $col["extension"]
    }' <<<"$table")
  assert_equals "sub-11	task-balloonanalogrisktask	run-1	hemi-L	space-fsaverage5	bold	func.gii" \
    "$gii_row" "ds000001-fmriprep .func.gii row should be in the table" || return 1
  return 0
}

# The test sets plain variables with the names of internal arrays.
# shellcheck disable=SC2034,SC2128,SC2178
test_parse_bids_to_table_no_leaks() {
  # The parser and _libBIDSsh_parse_filename must not change the variables or
  # the shell options of the caller.
  local root
  root=$(_make_bidsignore_fixture)
  local out
  out=$(
    entities_order=EO entities_name_order=ENO entity_key=EK entity_name=EN
    file=F key=K parts=P i=I
    shopt -s extglob globstar
    shopt -u nullglob
    libBIDSsh_parse_bids_to_table "$root" >/dev/null
    declare -A info
    _libBIDSsh_parse_filename "sub-01_task-rest_bold.nii.gz" info
    echo "${entities_order} ${entities_name_order} ${entity_key} ${entity_name}" \
      "${file} ${key} ${parts} ${i}"
    shopt -p extglob nullglob globstar || true
  )
  assert_equals "EO ENO EK EN F K P I
shopt -s extglob
shopt -u nullglob
shopt -s globstar" "$out" "caller variables and shell options must not change"
}

test_parse_bids_to_table_symlinked_dirs() {
  # Files below a symbolic link to a directory must be in the table. A link
  # loop must not make the parser loop forever.
  local base root
  base=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  root="${base}/ds"
  mkdir -p "${base}/store/sub-02/anat" "${base}/store/fmriprep/sub-01/anat" \
    "${root}/sub-01/anat" "${root}/derivatives"
  : >"${base}/store/sub-02/anat/sub-02_T1w.nii.gz"
  : >"${base}/store/fmriprep/sub-01/anat/sub-01_desc-preproc_T1w.nii.gz"
  : >"${root}/sub-01/anat/sub-01_T1w.nii.gz"
  ln -s "${base}/store/sub-02" "${root}/sub-02"
  ln -s "${base}/store/fmriprep" "${root}/derivatives/fmriprep"
  ln -s .. "${root}/sub-01/anat/loop"

  local paths
  paths=$(libBIDSsh_parse_bids_to_table "$root" 2>/dev/null |
    awk -F '\t' 'NR > 1 { print $NF }')
  assert_equals "${root}/derivatives/fmriprep/sub-01/anat/sub-01_desc-preproc_T1w.nii.gz
${root}/sub-01/anat/sub-01_T1w.nii.gz
${root}/sub-02/anat/sub-02_T1w.nii.gz" "$paths" \
    "rows below symlinked directories, once each, in path order"
}

test_parse_bids_to_table_directory_recordings() {
  # A directory-type recording (.ds, .mefd, .ome.zarr) is one row. The files
  # inside it are not rows. A directory-only .bidsignore pattern ('*.ds/')
  # drops the directory row, in the parser and in libBIDSsh_apply_bidsignore.
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  mkdir -p "${root}/sub-01/meg/sub-01_task-a_meg.ds/sub" \
    "${root}/sub-01/micr/sub-01_sample-A_SPIM.ome.zarr/0"
  : >"${root}/sub-01/meg/sub-01_task-a_meg.ds/sub-01_task-a_meg.eeg"
  : >"${root}/sub-01/meg/sub-01_task-a_meg.ds/sub/sub-01_task-a_meg.json"
  : >"${root}/sub-01/micr/sub-01_sample-A_SPIM.ome.zarr/0/sub-01_SPIM.json"
  : >"${root}/sub-01/meg/sub-01_task-a_meg.json"

  local paths
  paths=$(libBIDSsh_parse_bids_to_table "$root" | awk -F '\t' 'NR > 1 { print $NF }')
  assert_equals "${root}/sub-01/meg/sub-01_task-a_meg.ds
${root}/sub-01/meg/sub-01_task-a_meg.json
${root}/sub-01/micr/sub-01_sample-A_SPIM.ome.zarr" "$paths" \
    "directory recordings are rows, their contents are not"

  printf '%s\n' '*.ds/' >"${root}/.bidsignore"
  paths=$(libBIDSsh_parse_bids_to_table "$root" | awk -F '\t' 'NR > 1 { print $NF }')
  assert_equals "${root}/sub-01/meg/sub-01_task-a_meg.json
${root}/sub-01/micr/sub-01_sample-A_SPIM.ome.zarr" "$paths" \
    "'*.ds/' in .bidsignore drops the .ds directory row"

  local raw
  raw=$(libBIDSsh_parse_bids_to_table --no-bidsignore "$root")
  paths=$(libBIDSsh_apply_bidsignore "$raw" "$root" | awk -F '\t' 'NR > 1 { print $NF }')
  assert_equals "${root}/sub-01/meg/sub-01_task-a_meg.json
${root}/sub-01/micr/sub-01_sample-A_SPIM.ome.zarr" "$paths" \
    "libBIDSsh_apply_bidsignore drops the .ds directory row for '*.ds/'"
}

test_parse_bids_to_table_core_files() {
  # Table files (participants, samples, phenotype/*) and suffix-only sidecars
  # (T1w.json) are rows. Their suffix is the whole stem. dataset_description.json
  # gets suffix 'dataset_description', not the atlas suffix 'description'.
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  mkdir -p "${root}/sub-01/anat" "${root}/phenotype" "${root}/derivatives/fs"
  local f
  for f in participants.tsv participants.json samples.tsv samples.json \
    phenotype/acds_adult.tsv phenotype/acds_adult.json dataset_description.json \
    T1w.json acq-x_T1w.json README CHANGES genetic_info.json \
    sub-01/participants.tsv sub-01/anat/sub-01_T1w.nii.gz \
    derivatives/fs/participants.tsv derivatives/fs/dataset_description.json; do
    : >"${root}/${f}"
  done

  local rows
  rows=$(libBIDSsh_parse_bids_to_table "$root" |
    awk -F '\t' -v root="${root}/" 'NR > 1 {
      sub(root, "", $NF); print $1, $2, $3, $10, $(NF - 2), $(NF - 1), $NF
    }' | LC_ALL=C sort)
  assert_equals "NA NA NA NA T1w json T1w.json
NA NA NA NA dataset_description json dataset_description.json
NA NA NA NA participants json participants.json
NA NA NA NA participants tsv participants.tsv
NA NA NA NA samples json samples.json
NA NA NA NA samples tsv samples.tsv
NA NA NA acq-x T1w json acq-x_T1w.json
NA anat sub-01 NA T1w nii.gz sub-01/anat/sub-01_T1w.nii.gz
NA phenotype NA NA acds_adult json phenotype/acds_adult.json
NA phenotype NA NA acds_adult tsv phenotype/acds_adult.tsv
fs NA NA NA dataset_description json derivatives/fs/dataset_description.json
fs NA NA NA participants tsv derivatives/fs/participants.tsv" "$rows" \
    "core, table and suffix-only files with the stem as suffix"
}

test_parse_bids_to_table_discovery_bids_examples() {
  # The same file discovery on real bids-examples datasets.
  local paths
  paths=$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds000246" |
    awk -F '\t' -v root="${bids_examples}/ds000246/" 'NR > 1 && $NF ~ /\.ds(\/|$)/ {
      sub(root, "", $NF); print $NF
    }' | LC_ALL=C sort)
  assert_equals "sub-0001/meg/sub-0001_task-AEF_run-01_meg.ds
sub-0001/meg/sub-0001_task-AEF_run-02_meg.ds
sub-emptyroom/meg/sub-emptyroom_task-noise_run-01_meg.ds" "$paths" \
    "ds000246: the .ds directories are rows, the files inside them are not"

  local rows
  rows=$({
    libBIDSsh_parse_bids_to_table "${bids_examples}/ds001"
    libBIDSsh_parse_bids_to_table "${bids_examples}/ds000248"
  } | awk -F '\t' -v ex="${bids_examples}/" '
      $NF ~ /\/(ds001\/participants\.tsv|ds000248\/T1w\.json)$/ {
        sub(ex, "", $NF); print $2, $(NF - 2), $(NF - 1), $NF
      }')
  assert_equals "NA participants tsv ds001/participants.tsv
NA T1w json ds000248/T1w.json" "$rows" \
    "ds001 participants.tsv and ds000248 root T1w.json are rows"

  rows=$(libBIDSsh_parse_bids_to_table "${bids_examples}/pheno004" |
    awk -F '\t' -v root="${bids_examples}/pheno004/" '$2 == "phenotype" {
      sub(root, "", $NF); print $(NF - 2), $(NF - 1), $NF
    }' | LC_ALL=C sort)
  assert_equals "ace json phenotype/ace.json
ace tsv phenotype/ace.tsv
demographics json phenotype/demographics.json
demographics tsv phenotype/demographics.tsv" "$rows" \
    "pheno004: phenotype files have datatype 'phenotype'"
}

test_table_filter() {
  local table="col1	col2	col3
A	B	C
1	2	3
NA	B	C"

  local filtered
  filtered=$(libBIDSsh_table_filter "$table" -c "col1,col3")
  assert_equals "col1	col3
A	C
1	3
NA	C" "$filtered" "should keep only col1 and col3" || return 1

  local row_filtered
  row_filtered=$(libBIDSsh_table_filter "$table" -r "col2:B")
  assert_equals "col1	col2	col3
A	B	C
NA	B	C" "$row_filtered" "should keep only rows with col2=B" || return 1

  local invert_filtered
  invert_filtered=$(libBIDSsh_table_filter "$table" -r "col2:B" -v)
  assert_equals "col1	col2	col3
1	2	3" "$invert_filtered" "should keep only rows without col2=B" || return 1

  local drop_na_filtered
  drop_na_filtered=$(libBIDSsh_table_filter "$table" -d "col1")
  assert_equals "col1	col2	col3
A	B	C
1	2	3" "$drop_na_filtered" "should drop NA in col1" || return 1

  return 0
}

test_table_filter_patterns() {
  # Row filter patterns: split at the first ':' only, no backslash escape
  # processing, POSIX bracket classes, exact complement for --invert.
  local out

  local table="a	path
1	x:y
2	xnz
3	x.z"
  out=$(libBIDSsh_table_filter "$table" -r "path:x:z")
  assert_equals "a	path" "$out" "pattern with ':' must not be cut at the second ':'" || return 1

  out=$(libBIDSsh_table_filter "$table" -r 'path:^x\.z$' 2>&1)
  assert_equals "a	path
3	x.z" "$out" "'\\.' must match a literal dot, with no warning" || return 1

  out=$(libBIDSsh_table_filter "$table" -c a -r 'a:^[[:digit:]]+$')
  assert_equals "a
1
2
3" "$out" "POSIX bracket class in pattern" || return 1

  table="subject	suffix
sub-01	T1w
sub-01	bold
sub-02	bold"
  out=$(libBIDSsh_table_filter "$table" -r "suffix:bold" -r "subject:^sub-01$" -v)
  assert_equals "subject	suffix
sub-01	T1w
sub-02	bold" "$out" "--invert removes only rows that match all -r filters" || return 1

  return 0
}

test_table_filter_invert_complement() {
  # Rows kept by the -r filters plus rows kept with --invert = all rows.
  local full total matched inverted
  full=$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds001")
  total=$(($(wc -l <<<"$full") - 1))
  matched=$(($(libBIDSsh_table_filter "$full" -r "task:balloon" -r "subject:^sub-01$" | wc -l) - 1))
  inverted=$(($(libBIDSsh_table_filter "$full" -r "task:balloon" -r "subject:^sub-01$" -v | wc -l) - 1))
  assert_equals "$total" "$((matched + inverted))" "normal + inverted rows = all rows (ds001)" || return 1

  return 0
}

test_table_filter_ds001() {
  # Column order, row filter and a backslash pattern on real data (ds001).
  local full out err
  full=$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds001")

  out=$(libBIDSsh_table_filter "$full" -c "path,subject,run" -r "suffix:^bold$")
  assert_equals "path	subject	run" "$(head -n 1 <<<"$out")" "-c keeps the requested order (ds001)" || return 1
  assert_equals "49" "$(($(wc -l <<<"$out") - 1))" "-r 'suffix:^bold$' row count (ds001)" || return 1

  out=$(libBIDSsh_table_filter "$full" -r 'extension:^nii\.gz$' 2>"${test_tmpdir}/err")
  err=$(<"${test_tmpdir}/err")
  assert_equals "80" "$(($(wc -l <<<"$out") - 1))" "-r 'extension:^nii\\.gz$' row count (ds001)" || return 1
  assert_equals "" "$err" "'\\.' in a pattern must not give a warning (ds001)" || return 1

  return 0
}

test_table_filter_columns() {
  # Column selection: requested order, first of duplicate names, errors for
  # unknown names, index 0, index > NF and a missing option argument.
  local out err rc

  local table="c1	c2	c3	c4	c5	c6	c7	c8	c9	c10	c11	c12
1	2	3	4	5	6	7	8	9	10	11	12"
  out=$(libBIDSsh_table_filter "$table" -c "c12,c3,c10,c1")
  assert_equals "c12	c3	c10	c1
12	3	10	1" "$out" "-c keeps the requested order" || return 1

  out=$(libBIDSsh_table_filter "subject	json_path	json_path
sub-01	/a.json	NA" -c json_path)
  assert_equals "json_path
/a.json" "$out" "duplicate header name selects the first column" || return 1

  table="subject	task
sub-01	task-rest"
  local spec
  for spec in "-c sub" "-c 0" "-c 3" "-c subject,,task" "-r sub:x" "-d sub"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(libBIDSsh_table_filter "$table" $spec 2>"${test_tmpdir}/err") || rc=$?
    err=$(<"${test_tmpdir}/err")
    assert_equals "1" "$rc" "'${spec}' must return 1" || return 1
    assert_equals "" "$out" "'${spec}' must print nothing to stdout" || return 1
    assert_contains "not found in header" "$err" "'${spec}' error message" || return 1
  done

  rc=0
  out=$(libBIDSsh_table_filter "subject	task" -r "sub:x" 2>/dev/null) || rc=$?
  assert_equals "1" "$rc" "unknown -r column on a header-only table must return 1" || return 1

  local opt
  for opt in -c -r -d; do
    rc=0
    err=$( (libBIDSsh_table_filter "$table" "$opt") 2>&1) || rc=$?
    assert_equals "1" "$rc" "'${opt}' without an argument must return 1" || return 1
    assert_contains "requires an argument" "$err" "'${opt}' without an argument" || return 1
  done

  rc=0
  err=$(libBIDSsh_table_filter "$table" -r "subject" 2>&1) || rc=$?
  assert_equals "1" "$rc" "-r without ':' must return 1" || return 1

  return 0
}

test_table_filter_posix_awk() {
  # The awk program must use POSIX awk only (mawk, BSD awk, gawk --posix).
  if ! command -v gawk >/dev/null 2>&1; then
    skip_test "gawk not found"
  fi
  local awkdir="${test_tmpdir}/posix_awk"
  mkdir -p "${awkdir}"
  printf '#!/bin/sh\nexec gawk --posix "$@"\n' >"${awkdir}/awk"
  chmod +x "${awkdir}/awk"

  local table="subject	task	run
sub-01	task-rest	run-1
sub-02	task-rest	NA"
  local out rc=0
  out=$(PATH="${awkdir}:${PATH}" libBIDSsh_table_filter "$table" \
    -c "run,subject" -r "task:rest" -r "subject:^sub-0[12]$" -d run 2>&1) || rc=$?
  assert_equals "0" "$rc" "table_filter must run on gawk --posix" || return 1
  assert_equals "run	subject
run-1	sub-01" "$out" "table_filter output on gawk --posix" || return 1

  return 0
}

test_empty_arrays_nounset() {
  # Bash < 4.4 treats "${arr[@]}" on an empty array as unbound under set -u.
  # Run the common calls with empty internal arrays (no -r filters, no custom
  # entities, no sort columns, empty result) and require no stderr output.
  # This test only catches regressions when the suite runs on bash 4.3.
  local table="col1	col2
A	B
1	2"
  local out err

  err=$( (set -u; libBIDSsh_table_filter "$table" -c "col1" >/dev/null) 2>&1)
  assert_equals "" "$err" "table_filter without -r must not error" || return 1
  out=$(set -u; libBIDSsh_table_filter "$table" -c "col1")
  assert_equals "col1
A
1" "$out" "table_filter without -r should keep col1" || return 1

  err=$( (set -u; libBIDSsh_parse_bids_to_table "${bids_examples}/ds001" >/dev/null) 2>&1)
  assert_equals "" "$err" "parser without custom entities must not error" || return 1

  out=$(
    set -u
    declare -a values
    libBIDSsh_table_column_to_array "col1	col2" "col1" values true true
    echo "n=${#values[@]}"
  ) 2>&1
  assert_equals "n=0" "$out" "column_to_array on a header-only table" || return 1

  out=$(
    set -u
    declare -A row
    local n=0
    while libBIDSsh_table_iterator "$table" row; do n=$((n + 1)); done
    echo "n=${n}"
  ) 2>&1
  assert_equals "n=2" "$out" "iterator without sort columns or -r" || return 1

  return 0
}

test_drop_na_columns() {
  local table="col1	col2	col3
A	NA	C
1	NA	3"

  local cleaned
  cleaned=$(libBIDSsh_drop_na_columns "$table")
  assert_equals "col1	col3
A	C
1	3" "$cleaned" "should drop col2 because it's only NA" || return 1

  return 0
}

test_drop_na_columns_short_last_row() {
  # The column count comes from the header, not from the last row.
  local table="a	b	c
1	NA	3
4	NA"

  local cleaned
  cleaned=$(libBIDSsh_drop_na_columns "$table")
  assert_equals "a	c
1	3
4	" "$cleaned" "short last row should not drop column c" || return 1

  return 0
}

test_drop_na_columns_trailing_newline() {
  # A trailing newline must not remove all columns.
  local table
  table=$'a\tb\tc\nNA\t1\tNA\n2\tNA\tNA\n'

  local cleaned
  cleaned=$(libBIDSsh_drop_na_columns "$table")
  assert_equals "a	b
NA	1
2	NA" "$cleaned" "trailing newline should keep data columns" || return 1

  return 0
}

test_drop_na_columns_header_only() {
  # A table without data rows keeps its header.
  local cleaned
  cleaned=$(libBIDSsh_drop_na_columns "subject	task	path")
  assert_equals "subject	task	path" "$cleaned" \
    "header-only table should keep its header" || return 1

  return 0
}

test_drop_na_columns_bids_examples() {
  # On real data, keep exactly the columns that have a value that is not NA.
  local table
  table=$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds001")

  # Find the expected header column by column, without drop_na_columns.
  local -a header_fields
  IFS=$'\t' read -r -a header_fields <<<"${table%%$'\n'*}"
  local expected="" i
  for ((i = 1; i <= ${#header_fields[@]}; i++)); do
    # grep -c reads all input; grep -q can exit early, and then cut gets
    # SIGPIPE and pipefail makes the test fail at random.
    if (($(tail -n +2 <<<"$table" | cut -f "$i" | grep -cvx 'NA' || true) > 0)); then
      expected+="${expected:+$'\t'}${header_fields[i - 1]}"
    fi
  done

  local cleaned
  cleaned=$(libBIDSsh_drop_na_columns "$table")
  assert_equals "$expected" "$(head -n 1 <<<"$cleaned")" \
    "ds001 should keep only the columns that have data" || return 1

  cleaned=$(libBIDSsh_drop_na_columns "${table}"$'\n')
  assert_equals "$expected" "$(head -n 1 <<<"$cleaned")" \
    "ds001 with a trailing newline should keep the columns that have data" || return 1
  assert_equals "$(wc -l <<<"$table")" "$(wc -l <<<"$cleaned")" \
    "ds001 with a trailing newline should keep all rows" || return 1

  return 0
}

test_extension_json_rows_to_column_json_path() {
  local table="extension	path	subject
nii.gz	/path/to/data.nii.gz	sub-1
json	/path/to/data.json	sub-1
nii.gz	/path/to/other.nii.gz	sub-2"

  local updated
  updated=$(libBIDSsh_extension_json_rows_to_column_json_path "$table")

  # The json row is removed, its path goes to the matching row, and a row
  # without a sidecar gets NA.
  assert_equals "extension	path	subject	json_path
nii.gz	/path/to/data.nii.gz	sub-1	/path/to/data.json
nii.gz	/path/to/other.nii.gz	sub-2	NA" "$updated" "should fold json rows into json_path" || return 1

  return 0
}

test_extension_json_rows_to_column_json_path_trailing_newline() {
  local table
  table="$(printf 'subject\tsuffix\textension\tpath\nsub-01\tbold\tnii.gz\t/a_bold.nii.gz\n\n')"
  # Command substitution strips trailing newlines; add them back.
  table+=$'\n\n'

  local updated
  updated=$(libBIDSsh_extension_json_rows_to_column_json_path "$table")

  # Empty lines must not become "<empty>\tNA" rows.
  assert_equals "subject	suffix	extension	path	json_path
sub-01	bold	nii.gz	/a_bold.nii.gz	NA" "$updated" "should ignore empty lines" || return 1

  return 0
}

test_extension_json_rows_to_column_json_path_idempotent() {
  local table="subject	suffix	extension	path
sub-01	bold	nii.gz	/a_bold.nii.gz
sub-01	bold	json	/a_bold.json"

  local once twice
  once=$(libBIDSsh_extension_json_rows_to_column_json_path "$table")
  twice=$(libBIDSsh_extension_json_rows_to_column_json_path "$once")

  # A second call must not add a second json_path column.
  assert_equals "subject	suffix	extension	path	json_path
sub-01	bold	nii.gz	/a_bold.nii.gz	/a_bold.json" "$twice" "second call should return the table unchanged" || return 1

  return 0
}

test_extension_json_rows_to_column_json_path_bids_examples() {
  # asl001 has JSON sidecars with the same name as their data files.
  local table once
  table=$(libBIDSsh_parse_bids_to_table "${bids_examples}/asl001")
  once=$(libBIDSsh_extension_json_rows_to_column_json_path "$table")

  # A trailing newline must not add a row.
  assert_equals "$once" \
    "$(libBIDSsh_extension_json_rows_to_column_json_path "${table}"$'\n')" \
    "asl001 with a trailing newline should give the same rows" || return 1

  # A second call must not add a second json_path column.
  assert_equals "$once" \
    "$(libBIDSsh_extension_json_rows_to_column_json_path "$once")" \
    "asl001 second call should return the table unchanged" || return 1

  return 0
}

test_table_column_to_array() {
  local table="subject	session
sub-01	ses-1
sub-01	ses-2
sub-02	ses-1"

  declare -a subjects
  libBIDSsh_table_column_to_array "$table" "subject" subjects true true
  assert_equals "2" "${#subjects[@]}" "should have 2 unique subjects" || return 1
  assert_equals "sub-01" "${subjects[0]}" "first should be sub-01" || return 1
  assert_equals "sub-02" "${subjects[1]}" "second should be sub-02" || return 1

  return 0
}

# Each case runs in its own $(...) subshell on purpose.
# shellcheck disable=SC2030,SC2031
test_table_column_to_array_edge_cases() {
  local table="subject	session	path
sub-01	NA	/a
sub-01	NA	/b
sub-02	NA	/c"
  local out rc

  # A column that exists but has only NA values gives an empty array, not
  # an error.
  out=$(
    exec 2>&1
    declare -a values=(stale)
    rc=0
    libBIDSsh_table_column_to_array "$table" "session" values || rc=$?
    echo "rc=${rc} n=${#values[@]}"
  )
  assert_equals "rc=0 n=0" "$out" "all-NA column must give rc=0 and an empty array" || return 1

  # A column that is not in the header is an error, also with no data rows.
  rc=0
  out=$(
    exec 2>&1
    declare -a values
    libBIDSsh_table_column_to_array "subject	path" "bogus" values
  ) || rc=$?
  assert_equals "1" "$rc" "missing column on a header-only table must give rc=1" || return 1
  assert_contains "not found" "$out" "missing column must print an error" || return 1

  # Column indices outside 1..number of columns are errors.
  rc=0
  (declare -a values; libBIDSsh_table_column_to_array "$table" 0 values) 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "column index 0 must give rc=1" || return 1
  rc=0
  (declare -a values; libBIDSsh_table_column_to_array "$table" 4 values) 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "column index > NF must give rc=1" || return 1

  # A trailing newline and empty values must not crash the unique filter.
  out=$(
    exec 2>&1
    declare -a values
    libBIDSsh_table_column_to_array $'subject\tpath\nsub-01\t/a\n' "subject" values
    declare -p values
  )
  assert_equals "$(declare -a values=(sub-01); declare -p values)" "$out" \
    "trailing newline must not add an empty value" || return 1
  out=$(
    exec 2>&1
    declare -a values
    libBIDSsh_table_column_to_array $'subject\tpath\nsub-01\t/a\n\t/b\n\t/c' "subject" values
    declare -p values
  )
  assert_equals "$(declare -a values=(sub-01 ""); declare -p values)" "$out" \
    "empty values must be unique-filtered without error" || return 1

  # The function must not change the caller's variables, and must fill
  # caller arrays that have the same names as the old internal variables.
  out=$(
    exec 2>&1
    item=keep
    line=keep
    declare -a values
    libBIDSsh_table_column_to_array "$table" "subject" values
    echo "item=${item} line=${line}"
  )
  assert_equals "item=keep line=keep" "$out" "caller item/line must not change" || return 1
  local name
  for name in line item seen unique_array table_data array_ref column; do
    out=$(
      exec 2>&1
      declare -a "${name}"
      libBIDSsh_table_column_to_array "$table" "subject" "${name}" true true
      local -n _out_ref="${name}"
      echo "${_out_ref[*]}"
    )
    assert_equals "sub-01 sub-02" "$out" "caller array named '${name}'" || return 1
  done

  return 0
}

test_table_column_to_array_bids_examples() {
  # On real data, an all-NA column gives an empty array and status 0.
  local table
  table=$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds001")

  local -a subjects=()
  libBIDSsh_table_column_to_array "$table" "subject" subjects
  local expected
  expected=$(find "${bids_examples}/ds001" -mindepth 1 -maxdepth 1 -type d \
    -name 'sub-*' | wc -l)
  assert_equals "16" "${expected// /}" "ds001 should have 16 subject folders" || return 1
  assert_equals "${expected// /}" "${#subjects[@]}" \
    "ds001 should give one value for each subject" || return 1

  # ds001 has no sessions, so the session column has only NA values.
  local out
  out=$(
    exec 2>&1
    declare -a sessions=(stale)
    rc=0
    libBIDSsh_table_column_to_array "$table" "session" sessions || rc=$?
    echo "rc=${rc} n=${#sessions[@]}"
  )
  assert_equals "rc=0 n=0" "$out" \
    "ds001 session column should give rc=0 and an empty array" || return 1

  return 0
}

test_table_iterator() {
  # Input is not sorted, so the order shows that the sort column is used.
  local table="subject	session
sub-02	ses-2
sub-01	ses-1
sub-03	ses-3"

  declare -A row
  local count=0
  local subj_str=""
  local ses_str=""
  while libBIDSsh_table_iterator "$table" row "subject"; do
    count=$((count + 1))
    subj_str="${subj_str}${row[subject]} "
    ses_str="${ses_str}${row[session]} "
  done

  assert_equals "3" "$count" "should iterate 3 times" || return 1
  assert_equals "sub-01 sub-02 sub-03 " "$subj_str" "should sort by subject" || return 1
  assert_equals "ses-1 ses-2 ses-3 " "$ses_str" "session should stay with its row" || return 1

  subj_str=""
  while libBIDSsh_table_iterator "$table" row "subject" -r; do
    subj_str="${subj_str}${row[subject]} "
  done
  assert_equals "sub-03 sub-02 sub-01 " "$subj_str" "-r should reverse the sort" || return 1
  return 0
}

test_table_iterator_direct_call() {
  # A call outside a "while" or "if" must not stop the caller under set -e,
  # and the row array must hold only the column keys.
  local table="a	b
1	2
3	4"
  declare -A row
  libBIDSsh_table_iterator "$table" row
  assert_equals "1 2" "${row[a]} ${row[b]}" "first direct call gives the first row" || return 1
  local keys
  keys="$(printf '%s\n' "${!row[@]}" | sort | tr '\n' ' ')"
  assert_equals "a b " "$keys" "row keys must be the column names only" || return 1
  libBIDSsh_table_iterator "$table" row
  assert_equals "3 4" "${row[a]} ${row[b]}" "second direct call gives the second row" || return 1
  local rc=0
  libBIDSsh_table_iterator "$table" row || rc=$?
  assert_equals "1" "$rc" "call after the last row returns 1" || return 1
  assert_equals "0" "${#row[@]}" "row is empty after the last row" || return 1
  return 0
}

test_table_iterator_state() {
  # The cursor is not kept in the row array. A different table or different
  # sort arguments start a new iteration. The same table continues.
  local t1="a
1
2
3"
  local t2="a
x
y
z"
  declare -A row
  local out=""

  while libBIDSsh_table_iterator "$t1" row; do
    [[ "${row[a]}" == "2" ]] && break
  done
  while libBIDSsh_table_iterator "$t2" row; do out+="${row[a]} "; done
  assert_equals "x y z " "$out" "a new table after break starts at its first row" || return 1

  out=""
  while libBIDSsh_table_iterator "$t1" row; do
    [[ "${row[a]}" == "1" ]] && break
  done
  while libBIDSsh_table_iterator "$t1" row -r; do out+="${row[a]} "; done
  assert_equals "3 2 1 " "$out" "new sort arguments after break start again" || return 1

  out=""
  while libBIDSsh_table_iterator "$t1" row; do
    [[ "${row[a]}" == "1" ]] && break
  done
  while libBIDSsh_table_iterator "$t1" row; do out+="${row[a]} "; done
  assert_equals "2 3 " "$out" "same table after break continues" || return 1

  out=""
  while libBIDSsh_table_iterator "$t1" row; do
    [[ "${row[a]}" == "1" ]] && break
  done
  row=()
  while libBIDSsh_table_iterator "$t1" row; do out+="${row[a]} "; done
  assert_equals "1 2 3 " "$out" "row=() after break starts again" || return 1

  out=""
  while libBIDSsh_table_iterator "$t1" row; do
    [[ "${row[a]}" == "1" ]] && break
  done
  libBIDSsh_table_iterator "" row || true
  while libBIDSsh_table_iterator "$t1" row; do out+="${row[a]} "; done
  assert_equals "1 2 3 " "$out" "an empty table resets the cursor" || return 1

  # A new array that is declared but has no value starts again, also when
  # saved state for that array name stays after a break (set -u is on).
  # The helper runs in this shell (not in a subshell), so the state stays.
  local _iter_out=""
  _iter_first_row() {
    local -A row
    while libBIDSsh_table_iterator "$t1" row; do
      _iter_out+="${row[a]} "
      [[ "${row[a]}" == "1" ]] && break
    done
  }
  _iter_first_row
  _iter_out+="|"
  _iter_first_row
  unset -f _iter_first_row
  assert_equals "1 |1 " "$_iter_out" "local -A row after break starts again" || return 1

  out=""
  while libBIDSsh_table_iterator "$t1" row; do
    [[ "${row[a]}" == "1" ]] && break
  done
  unset row
  declare -A row
  while libBIDSsh_table_iterator "$t1" row; do out+="${row[a]} "; done
  assert_equals "1 2 3 " "$out" "unset row and declare -A row starts again" || return 1

  local t3="__current_line	b
7	p"
  declare -A r
  libBIDSsh_table_iterator "$t3" r
  assert_equals "7" "${r[__current_line]}" "a column named __current_line keeps its value" || return 1

  # Nested loops with different array names are independent.
  declare -A inner
  out=""
  while libBIDSsh_table_iterator "$t1" row; do
    while libBIDSsh_table_iterator "$t2" inner; do out+="${row[a]}${inner[a]} "; done
  done
  assert_equals "1x 1y 1z 2x 2y 2z 3x 3y 3z " "$out" "nested loops with two arrays" || return 1
  return 0
}

test_table_iterator_empty_fields() {
  # Empty fields must stay in their column (tab is not collapsed).
  local table="a	b	c
1		3
4	5	"
  declare -A row
  local out=""
  while libBIDSsh_table_iterator "$table" row; do
    out+="[${row[a]}|${row[b]}|${row[c]}]"
  done
  assert_equals "[1||3][4|5|]" "$out" "empty fields keep their column" || return 1
  return 0
}

# These names are arrays in other tests; here they are plain strings on purpose.
# shellcheck disable=SC2128,SC2178
test_table_iterator_no_globals() {
  # The iterator must not change caller variables or add globals other than
  # its own _LIBBIDSSH_ITER_* state.
  local table="a	b
2	x
1	y"
  local i=I lines=L headers=H values=V col=C arg=A sorted_data=S
  local before after
  before="$(compgen -v | sort)"
  declare -A row
  local n=0
  while libBIDSsh_table_iterator "$table" row a; do n=$((n + 1)); done
  after="$(compgen -v | sort)"
  assert_equals "2" "$n" "iterates 2 rows" || return 1
  assert_equals "I L H V C A S" "$i $lines $headers $values $col $arg $sorted_data" \
    "caller variables are not changed" || return 1
  local added
  added="$(comm -13 <(echo "$before") <(echo "$after") |
    grep -v -e '^_LIBBIDSSH_ITER_' -e '^before$' -e '^row$' -e '^n$' || true)"
  assert_equals "" "$added" "no new global variables" || return 1
  return 0
}

test_table_iterator_array_names() {
  # The row array can have the name of a local variable of the iterator
  # (for example "line" or "i"). The name reference must not resolve to a
  # local of the iterator.
  local table="a	b
2	x
1	y"
  local out=""
  declare -A line
  while libBIDSsh_table_iterator "$table" line; do
    out+="${line[a]}${line[b]} "
  done
  assert_equals "1y 2x " "$out" "row array named 'line'" || return 1
  out=""
  declare -A i
  while libBIDSsh_table_iterator "$table" i a -r; do
    out+="${i[a]}${i[b]} "
  done
  assert_equals "2x 1y " "$out" "row array named 'i'" || return 1
  local nm
  for nm in arg col idx resume table_data row_headers args_sig row_count \
    arr_name arr_ref values headers lines header sorted_data current_line \
    sort_keys reverse_sort name count; do
    out=""
    eval "declare -A ${nm}=()"
    while libBIDSsh_table_iterator "$table" "${nm}"; do
      eval "out+=\"\${${nm}[a]}\${${nm}[b]} \""
    done
    assert_equals "1y 2x " "$out" "row array named '${nm}'" || return 1
    unset "${nm}"
  done
  # Names with the reserved prefix give an error
  declare -A _lbit_row=()
  local rc=0
  libBIDSsh_table_iterator "$table" _lbit_row 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "reserved prefix '_lbit_' is refused" || return 1
  return 0
}

test_table_iterator_bids_examples() {
  # Iterate a real table (ds001). Each row gives the same order as "sort"
  # for the same keys, and the row array holds only the column names.
  local table table2
  table="$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds001")"
  table2="$(libBIDSsh_parse_bids_to_table "${bids_examples}/ds002")"
  local ncols nrows sc rc pc
  ncols="$(head -n 1 <<<"$table" | awk -F'\t' '{print NF}')"
  nrows="$(tail -n +2 <<<"$table" | wc -l | tr -d ' ')"
  sc="$(head -n 1 <<<"$table" | tr '\t' '\n' | grep -n -x subject | cut -d: -f1)"
  rc="$(head -n 1 <<<"$table" | tr '\t' '\n' | grep -n -x run | cut -d: -f1)"
  pc="$(head -n 1 <<<"$table" | tr '\t' '\n' | grep -n -x path | cut -d: -f1)"
  local expected
  expected="$(tail -n +2 <<<"$table" |
    sort --version-sort -t$'\t' "-k${sc},${sc}" "-k${rc},${rc}" | cut -f "${pc}")"

  declare -A row
  local n=0 bad_keys=0 got=""
  while libBIDSsh_table_iterator "$table" row subject run; do
    n=$((n + 1))
    ((${#row[@]} == ncols)) || bad_keys=$((bad_keys + 1))
    got+="${row[path]}"$'\n'
  done
  assert_equals "${nrows}" "$n" "ds001: one iteration for each data row" || return 1
  assert_equals "0" "$bad_keys" "ds001: row keys are the column names only" || return 1
  assert_equals "$expected" "${got%$'\n'}" "ds001: order is the same as sort" || return 1

  # A direct call (not in "while" or "if") must not stop the test under set -e
  libBIDSsh_table_iterator "$table" row subject run
  assert_equals "$(head -n 1 <<<"$expected")" "${row[path]}" \
    "ds001: direct call gives the first sorted row" || return 1

  # The direct call leaves an open iteration on ds001, as a "break" does.
  # A loop over a different table (ds002) must start at its first row.
  local n2=0
  n2="$(tail -n +2 <<<"$table2" | wc -l | tr -d ' ')"
  n=0
  while libBIDSsh_table_iterator "$table2" row; do n=$((n + 1)); done
  assert_equals "${n2}" "$n" "ds002 after a break on ds001: all rows" || return 1
  return 0
}

test_json_to_associative_array() {
  command -v jq >/dev/null 2>&1 || skip_test "jq not found"
  local json_file
  json_file="$(mktemp -d "${test_tmpdir}/json.XXXXXX")/dataset_description.json"
  printf '%s\n' '{"Name": "Test dataset", "BIDSVersion": "1.0.2",' \
    '"RepetitionTime": 2.5, "Authors": ["A", "B"]}' >"$json_file"

  declare -A json_data
  libBIDSsh_json_to_associative_array "$json_file" json_data

  assert_equals "4" "${#json_data[@]}" "should have 4 keys" || return 1
  assert_equals "string:Test dataset" "${json_data[Name]:-}" "Name value" || return 1
  assert_equals "string:1.0.2" "${json_data[BIDSVersion]:-}" "BIDSVersion value" || return 1
  assert_equals "number:2.5" "${json_data[RepetitionTime]:-}" "RepetitionTime value" || return 1
  assert_equals "array:A,B" "${json_data[Authors]:-}" "Authors value" || return 1
  return 0
}

test_json_to_associative_array_roundtrip() {
  command -v jq >/dev/null 2>&1 || skip_test "jq not found"
  local dir
  dir="$(mktemp -d "${test_tmpdir}/json.XXXXXX")"
  printf '%s\n' '{"k=eq": "v", "Multi": "line1\nline2", "Eq": "a=",' \
    '"q\"": 1, "\"lead": 2, "Objs": [{"a": 1}], "Nested": [[1, 2]],' \
    '"Mixed": [1, null, true, "x"], "Obj": {"b": 1}, "After": 1}' \
    >"${dir}/round.json"

  declare -A json_data
  libBIDSsh_json_to_associative_array "${dir}/round.json" json_data

  assert_equals "10" "${#json_data[@]}" "should have 10 keys" || return 1
  assert_equals "string:v" "${json_data[k=eq]:-}" "key with '='" || return 1
  assert_equals $'string:line1\nline2' "${json_data[Multi]:-}" "multi-line value" || return 1
  assert_equals "string:a=" "${json_data[Eq]:-}" "value with trailing '='" || return 1
  assert_equals "number:1" "${json_data[q\"]:-}" "key with trailing quote" || return 1
  assert_equals "number:2" "${json_data[\"lead]:-}" "key with leading quote" || return 1
  assert_equals 'array:{"a":1}' "${json_data[Objs]:-}" "array of objects" || return 1
  assert_equals 'array:[1,2]' "${json_data[Nested]:-}" "array of arrays" || return 1
  assert_equals "array:1,,true,x" "${json_data[Mixed]:-}" "array of scalars" || return 1
  assert_equals 'object:{"b":1}' "${json_data[Obj]:-}" "object value" || return 1
  assert_equals "number:1" "${json_data[After]:-}" "key after an array of objects" || return 1

  # An empty key cannot be an array subscript; it is skipped, not fatal.
  printf '%s\n' '{"": 1, "a": 2}' >"${dir}/empty_key.json"
  libBIDSsh_json_to_associative_array "${dir}/empty_key.json" json_data 2>/dev/null
  assert_equals "1" "${#json_data[@]}" "empty key should be skipped" || return 1
  assert_equals "number:2" "${json_data[a]:-}" "key after empty key" || return 1

  # A "\u0000" in a string must not move the keys that come after it.
  printf '%s\n' '{"a": "x\u0000y", "b": 1, "c": 2}' >"${dir}/nul.json"
  libBIDSsh_json_to_associative_array "${dir}/nul.json" json_data
  assert_equals "3" "${#json_data[@]}" "NUL: should have 3 keys" || return 1
  assert_equals "string:xy" "${json_data[a]:-}" "NUL is removed from value" || return 1
  assert_equals "number:1" "${json_data[b]:-}" "key b after a NUL value" || return 1
  assert_equals "number:2" "${json_data[c]:-}" "key c after a NUL value" || return 1
  return 0
}

test_json_to_associative_array_errors() {
  command -v jq >/dev/null 2>&1 || skip_test "jq not found"
  local dir rc
  dir="$(mktemp -d "${test_tmpdir}/json.XXXXXX")"
  printf '%s\n' '{"TaskName": "rest"}' >"${dir}/first.json"
  printf '%s\n' '{"X": 1}' >"${dir}/second.json"
  printf '%s\n' '{"bad":' >"${dir}/bad.json"
  printf '%s\n' '[1, 2]' >"${dir}/top_array.json"

  # Keys from a previous file must not stay in the array.
  declare -A json_data
  libBIDSsh_json_to_associative_array "${dir}/first.json" json_data
  libBIDSsh_json_to_associative_array "${dir}/second.json" json_data
  assert_equals "1" "${#json_data[@]}" "array should be cleared" || return 1
  assert_equals "NA" "${json_data[TaskName]:-NA}" "no stale TaskName" || return 1

  rc=0
  libBIDSsh_json_to_associative_array "${dir}/bad.json" json_data 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "invalid JSON should return 1" || return 1
  assert_equals "0" "${#json_data[@]}" "array should be empty on error" || return 1

  rc=0
  libBIDSsh_json_to_associative_array "${dir}/top_array.json" json_data 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "top-level array should return 1" || return 1
  assert_equals "0" "${#json_data[@]}" "no keys from a top-level array" || return 1

  # The target must be an associative array; JSON keys are not arithmetic.
  # shellcheck disable=SC2034 # read by name in the function
  local -a indexed_data=()
  rc=0
  libBIDSsh_json_to_associative_array "${dir}/first.json" indexed_data 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "indexed array target should return 1" || return 1

  rc=0
  (
    # Hide jq: an empty PATH in this subshell only.
    # shellcheck disable=SC2123
    PATH="${dir}/no_such_dir"
    hash -r
    libBIDSsh_json_to_associative_array "${dir}/first.json" json_data
  ) 2>/dev/null || rc=$?
  assert_equals "1" "$rc" "missing jq should return 1" || return 1
  return 0
}

test_json_to_associative_array_bids_examples() {
  # Real sidecars from bids-examples. GeneratedBy in a derivatives
  # dataset_description.json is an array of objects; the keys after it
  # must not be lost. A second file must not keep keys from the first.
  command -v jq >/dev/null 2>&1 || skip_test "jq not found"
  local deriv_desc="${bids_examples}/synthetic/derivatives/fmriprep/dataset_description.json"
  local bold_json="${bids_examples}/ds001/task-balloonanalogrisktask_bold.json"
  local err
  declare -A json_data
  err="$(libBIDSsh_json_to_associative_array "$deriv_desc" json_data 2>&1 >/dev/null)"
  libBIDSsh_json_to_associative_array "$deriv_desc" json_data
  assert_equals "" "$err" "fmriprep dataset_description.json: no error" || return 1
  local generated_by="${json_data[GeneratedBy]:-NA}"
  local acknowledge="${json_data[HowToAcknowledge]:-NA}"
  assert_equals 'array:{"Name":"fMRIPrep",' "${generated_by:0:25}" \
    "GeneratedBy: array of objects as JSON text" || return 1
  assert_equals "string:Please cite our paper" "${acknowledge:0:28}" \
    "HowToAcknowledge after GeneratedBy is kept" || return 1

  libBIDSsh_json_to_associative_array "$bold_json" json_data
  assert_equals "RepetitionTime TaskName " \
    "$(printf '%s\n' "${!json_data[@]}" | sort | tr '\n' ' ')" \
    "ds001 bold sidecar: no stale keys from the first file" || return 1
  # jq 1.6 writes 2.0 as "2"; jq 1.7 and later keep "2.0".
  local repetition_time="${json_data[RepetitionTime]:-NA}"
  [[ "$repetition_time" =~ ^number:2(\.0)?$ ]] && repetition_time="number:2"
  assert_equals "number:2" "$repetition_time" "ds001 RepetitionTime" || return 1
  return 0
}

# Build a small self-contained BIDS-shaped fixture with a .bidsignore.
# Echoes the temp directory path (below test_tmpdir, removed on exit).
_make_bidsignore_fixture() {
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  local files=(
    "sub-01/func/sub-01_task-rest_bold.nii.gz"
    "sub-02/func/sub-02_task-rest_bold.nii.gz"
    "sub-01/anat/sub-01_T1w.nii.gz"
    "sub-01/anat/sub-01_FLASH.nii.gz"
    "sourcedata/sub-01/anat/sub-01_T1w.nii.gz"
    "code/sub-01_T1w.nii.gz"
    "derivatives/junk/sub-01_desc-x_T1w.nii.gz"
  )
  local f
  for f in "${files[@]}"; do
    mkdir -p "${root}/$(dirname "$f")"
    : >"${root}/${f}"
  done
  printf '%s\n' '*_FLASH.nii.gz' '*_bold.nii.gz' '!sub-01_task-rest_bold.nii.gz' \
    >"${root}/.bidsignore"
  printf '%s' "$root"
}

# Count data rows (all non-empty lines after the header).
_row_count() { awk 'NR > 1 && $0 != "" { c++ } END { print c + 0 }' <<<"$1"; }

test_bidsignore_matcher() {
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  printf '%s\n' '*_bold.nii.gz' '!sub-01_task-rest_bold.nii.gz' 'derivatives/junk/' \
    'a/b/anchored.nii.gz' '**/deep_FLASH.nii.gz' >"${root}/.bidsignore"
  _libBIDSsh_compile_bidsignore "$root" 1

  local rc=0
  _chk() { # path expected(0=ignored,1=kept) msg
    if _libBIDSsh_path_is_ignored "$1"; then local got=0; else local got=1; fi
    assert_equals "$2" "$got" "$3" || rc=1
  }
  _chk "sub-02/func/sub-02_task-rest_bold.nii.gz" 0 "basename glob ignores bold" # ignored
  _chk "sub-01/func/sub-01_task-rest_bold.nii.gz" 1 "negation re-includes bold"  # kept
  _chk "code/script.py" 0 "default ignore: code/"                                # ignored
  _chk "sourcedata/x/y_bold.nii.gz" 0 "default ignore: sourcedata/"              # ignored
  _chk "derivatives/junk/sub-01_T1w.nii.gz" 0 "directory pattern ignores subtree" # ignored
  _chk "derivatives/keep/sub-01_T1w.nii.gz" 1 "derivatives not ignored by default" # kept
  _chk "a/b/anchored.nii.gz" 0 "anchored path matches at root"                   # ignored
  _chk "x/a/b/anchored.nii.gz" 1 "anchored path does not match at depth"         # kept
  _chk "sub-01/anat/deep_FLASH.nii.gz" 0 "globstar matches across dirs"          # ignored
  _chk ".git/config" 0 "default ignore: .**"                                     # ignored

  rm -rf "$root"
  return $rc
}

test_bidsignore_defaults_match_validator() {
  # The defaults follow bids-validator: root-anchored sourcedata/ code/ stimuli/
  # log/ doc/, and '.**'. Directories with these names below the root are kept.
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  _libBIDSsh_compile_bidsignore "$root" 1

  local rc=0
  _chk() { # path expected(0=ignored,1=kept) msg
    if _libBIDSsh_path_is_ignored "$1"; then local got=0; else local got=1; fi
    assert_equals "$2" "$got" "$3" || rc=1
  }
  _chk "doc/sub-01_T1w.nii.gz" 0 "default ignore: /doc/"
  _chk "log/sub-01_T1w.json" 0 "default ignore: /log/"
  _chk "stimuli/sub-01_T1w.nii.gz" 0 "default ignore: /stimuli/"
  _chk ".hidden/sub-01_T1w.nii.gz" 0 "default ignore: .** at root"
  _chk "sub-01/anat/.sub-01_T1w.nii.gz" 0 "default ignore: .** at depth"
  _chk "derivatives/p/code/sub-01_T1w.json" 1 "derivatives/p/code/ kept"
  _chk "derivatives/p/log/sub-01_T1w.json" 1 "derivatives/p/log/ kept"
  _chk "derivatives/p/sourcedata/sub-01/anat/sub-01_T1w.nii.gz" 1 \
    "derivatives/p/sourcedata/ kept"
  _chk "sub-01/code/sub-01_T1w.nii.gz" 1 "code/ below the root kept"
  _chk "docs/sub-01_T1w.nii.gz" 1 "docs/ not a validator default"

  rm -rf "$root"
  return $rc
}

test_bidsignore_parser() {
  local root
  root=$(_make_bidsignore_fixture)

  local default raw nodefault
  default=$(libBIDSsh_parse_bids_to_table "$root")
  raw=$(libBIDSsh_parse_bids_to_table --no-bidsignore "$root")
  nodefault=$(libBIDSsh_parse_bids_to_table --no-default-ignores "$root")

  local rc=0
  assert_equals "7" "$(_row_count "$raw")" "--no-bidsignore keeps all 7 files" || rc=1
  assert_equals "3" "$(_row_count "$default")" "default drops FLASH/bold/sourcedata/code" || rc=1
  assert_equals "5" "$(_row_count "$nodefault")" "--no-default-ignores keeps sourcedata+code" || rc=1

  # FLASH always dropped when honoring; sourcedata dropped only by defaults.
  [[ "$default" != *FLASH* ]] || { echo "    FLASH not dropped in default"; rc=1; }
  [[ "$nodefault" != *FLASH* ]] || { echo "    FLASH not dropped in --no-default-ignores"; rc=1; }
  [[ "$nodefault" == *sourcedata* ]] || { echo "    sourcedata missing in --no-default-ignores"; rc=1; }
  [[ "$default" != *sourcedata* ]] || { echo "    sourcedata not dropped by defaults"; rc=1; }
  # Negation keeps sub-01 rest bold but not sub-02.
  [[ "$default" == *"sub-01_task-rest_bold"* ]] || { echo "    negated bold missing"; rc=1; }
  [[ "$default" != *"sub-02_task-rest_bold"* ]] || { echo "    sub-02 bold not dropped"; rc=1; }

  rm -rf "$root"
  return $rc
}

test_bidsignore_parser_root_anchored_defaults() {
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  local files=(
    "sub-01/anat/sub-01_T1w.nii.gz"
    "doc/sub-01_T1w.nii.gz"
    "code/sub-01_T1w.nii.gz"
    "derivatives/p/code/sub-01_T1w.json"
    "derivatives/p/log/sub-01_T1w.json"
    "derivatives/p/sourcedata/sub-01/anat/sub-01_T1w.nii.gz"
  )
  local f
  for f in "${files[@]}"; do
    mkdir -p "${root}/$(dirname "$f")"
    : >"${root}/${f}"
  done

  local table rc=0
  table=$(libBIDSsh_parse_bids_to_table "$root")
  assert_equals "4" "$(_row_count "$table")" "root doc/ and code/ dropped" || rc=1
  [[ "$table" != *"${root}/doc/"* ]] || { echo "    doc/ not dropped"; rc=1; }
  assert_contains "derivatives/p/code/sub-01_T1w.json" "$table" \
    "derivatives code/ kept" || rc=1
  assert_contains "derivatives/p/log/sub-01_T1w.json" "$table" \
    "derivatives log/ kept" || rc=1
  assert_contains "derivatives/p/sourcedata/sub-01/anat/sub-01_T1w.nii.gz" "$table" \
    "derivatives sourcedata/ kept" || rc=1

  rm -rf "$root"
  return $rc
}

test_apply_bidsignore() {
  local root
  root=$(_make_bidsignore_fixture)

  local default raw applied
  default=$(libBIDSsh_parse_bids_to_table "$root")
  raw=$(libBIDSsh_parse_bids_to_table --no-bidsignore "$root")
  applied=$(libBIDSsh_apply_bidsignore "$raw" "$root")

  local rc=0
  assert_equals "$default" "$applied" "apply_bidsignore matches parser default" || rc=1

  rm -rf "$root"
  return $rc
}

test_apply_bidsignore_empty_fields() {
  # Empty TSV fields must not move the path column (IFS tab merging).
  local root
  root=$(mktemp -d "${test_tmpdir}/fixture.XXXXXX")
  local tab=$'\t'
  local header="derivatives${tab}desc${tab}path"
  local kept="NA${tab}${tab}${root}/sub-01/anat/sub-01_T1w.nii.gz"
  local dropped="NA${tab}${tab}${root}/doc/sub-01_T1w.nii.gz"
  local table
  table=$(printf '%s\n' "$header" "$kept" "$dropped")

  local applied rc=0
  applied=$(libBIDSsh_apply_bidsignore "$table" "$root") || rc=1
  assert_equals "$(printf '%s\n' "$header" "$kept")" "$applied" \
    "row with empty field kept, doc/ row dropped" || rc=1

  # Empty header field before the path column.
  local header2="derivatives${tab}${tab}path"
  applied=$(libBIDSsh_apply_bidsignore "$(printf '%s\n' "$header2" "$kept")" "$root") || rc=1
  assert_equals "$(printf '%s\n' "$header2" "$kept")" "$applied" \
    "empty header field does not shift path column" || rc=1

  rm -rf "$root"
  return $rc
}

test_main_entrypoint() {
  # Run libBIDS.sh as a script (with the bash that runs the tests).
  local script="${test_dir}/libBIDS.sh"
  local out err rc

  # No argument: error and usage on stderr, nothing on stdout, exit 1.
  rc=0
  out=$("$BASH" "$script" 2>"${test_tmpdir}/main.err") || rc=$?
  err=$(<"${test_tmpdir}/main.err")
  assert_equals "1" "$rc" "no argument exits 1" || return 1
  assert_equals "" "$out" "no argument writes nothing to stdout" || return 1
  assert_contains "error: the first argument must be a path" "$err" "no argument error on stderr" || return 1

  # --help and -h: usage on stdout, nothing on stderr, exit 0.
  local flag
  for flag in --help -h; do
    rc=0
    out=$("$BASH" "$script" "$flag" 2>"${test_tmpdir}/main.err") || rc=$?
    err=$(<"${test_tmpdir}/main.err")
    assert_equals "0" "$rc" "$flag exits 0" || return 1
    assert_contains "Usage: libBIDS.sh" "$out" "$flag usage on stdout" || return 1
    assert_contains "--no-bidsignore" "$out" "$flag lists parser options" || return 1
    assert_equals "" "$err" "$flag writes nothing to stderr" || return 1
  done

  # --help after another option also prints the usage.
  rc=0
  out=$("$BASH" "$script" --no-bidsignore --help 2>/dev/null) || rc=$?
  assert_equals "0" "$rc" "--no-bidsignore --help exits 0" || return 1
  assert_contains "Usage: libBIDS.sh" "$out" "--no-bidsignore --help usage on stdout" || return 1
}

echo "Starting libBIDS.sh test suite..."
echo "---"

run_test "Internal: _libBIDSsh_parse_filename" test_parse_filename
run_test "Internal: _libBIDSsh_parse_filename datatype/derivatives" test_parse_filename_datatype_derivatives
run_test "Public API: libBIDSsh_parse_bids_to_table" test_parse_bids_to_table
run_test "Public API: libBIDSsh_parse_bids_to_table without jq" test_parse_bids_to_table_without_jq
run_test "Internal: _libBIDSsh_load_custom_entities" test_load_custom_entities
run_test "Public API: libBIDSsh_parse_bids_to_table .func.gii" test_parse_bids_to_table_func_gii
run_test "Public API: libBIDSsh_parse_bids_to_table keeps caller state" test_parse_bids_to_table_no_leaks
run_test "Public API: libBIDSsh_parse_bids_to_table follows symlinked dirs" test_parse_bids_to_table_symlinked_dirs
run_test "Public API: libBIDSsh_parse_bids_to_table directory recordings" test_parse_bids_to_table_directory_recordings
run_test "Public API: libBIDSsh_parse_bids_to_table core and table files" test_parse_bids_to_table_core_files
run_test "Public API: libBIDSsh_parse_bids_to_table discovery on bids-examples" test_parse_bids_to_table_discovery_bids_examples
run_test "Public API: libBIDSsh_table_filter" test_table_filter
run_test "Public API: libBIDSsh_table_filter patterns and --invert" test_table_filter_patterns
run_test "Public API: libBIDSsh_table_filter --invert complement (ds001)" test_table_filter_invert_complement
run_test "Public API: libBIDSsh_table_filter on ds001 data" test_table_filter_ds001
run_test "Public API: libBIDSsh_table_filter column errors" test_table_filter_columns
run_test "Public API: libBIDSsh_table_filter on POSIX awk" test_table_filter_posix_awk
run_test "Bash 4.3: empty arrays under set -u" test_empty_arrays_nounset
run_test "Public API: libBIDSsh_drop_na_columns" test_drop_na_columns
run_test "Public API: libBIDSsh_drop_na_columns short last row" test_drop_na_columns_short_last_row
run_test "Public API: libBIDSsh_drop_na_columns trailing newline" test_drop_na_columns_trailing_newline
run_test "Public API: libBIDSsh_drop_na_columns header only" test_drop_na_columns_header_only
run_test "Public API: libBIDSsh_drop_na_columns bids-examples" test_drop_na_columns_bids_examples
run_test "Public API: libBIDSsh_extension_json_rows_to_column_json_path" test_extension_json_rows_to_column_json_path
run_test "libBIDSsh_extension_json_rows_to_column_json_path ignores empty lines" test_extension_json_rows_to_column_json_path_trailing_newline
run_test "libBIDSsh_extension_json_rows_to_column_json_path is idempotent" test_extension_json_rows_to_column_json_path_idempotent
run_test "libBIDSsh_extension_json_rows_to_column_json_path bids-examples" test_extension_json_rows_to_column_json_path_bids_examples
run_test "Public API: libBIDSsh_table_column_to_array" test_table_column_to_array
run_test "Public API: libBIDSsh_table_column_to_array edge cases" test_table_column_to_array_edge_cases
run_test "Public API: libBIDSsh_table_column_to_array bids-examples" test_table_column_to_array_bids_examples
run_test "Public API: libBIDSsh_table_iterator" test_table_iterator
run_test "Public API: libBIDSsh_table_iterator direct call" test_table_iterator_direct_call
run_test "Public API: libBIDSsh_table_iterator state" test_table_iterator_state
run_test "Public API: libBIDSsh_table_iterator empty fields" test_table_iterator_empty_fields
run_test "Public API: libBIDSsh_table_iterator no globals" test_table_iterator_no_globals
run_test "Public API: libBIDSsh_table_iterator array names" test_table_iterator_array_names
run_test "Public API: libBIDSsh_table_iterator on bids-examples" test_table_iterator_bids_examples
run_test "Public API: libBIDSsh_json_to_associative_array" test_json_to_associative_array
run_test "Public API: libBIDSsh_json_to_associative_array round-trip" test_json_to_associative_array_roundtrip
run_test "Public API: libBIDSsh_json_to_associative_array errors" test_json_to_associative_array_errors
run_test "Public API: libBIDSsh_json_to_associative_array on bids-examples" test_json_to_associative_array_bids_examples
run_test "Internal: _libBIDSsh_path_is_ignored (.bidsignore matcher)" test_bidsignore_matcher
run_test "Internal: default ignores match bids-validator" test_bidsignore_defaults_match_validator
run_test "Public API: libBIDSsh_parse_bids_to_table .bidsignore" test_bidsignore_parser
run_test "Public API: libBIDSsh_parse_bids_to_table root-anchored defaults" test_bidsignore_parser_root_anchored_defaults
run_test "Public API: libBIDSsh_apply_bidsignore" test_apply_bidsignore
run_test "Public API: libBIDSsh_apply_bidsignore empty fields" test_apply_bidsignore_empty_fields
run_test "Main block: direct execution" test_main_entrypoint

echo "---"
echo "Test summary:"
echo "Executed: $tests_run"
echo "Passed:   $tests_passed"
echo "Failed:   $tests_failed"
echo "Skipped:  $tests_skipped"

if ((tests_failed > 0)); then
  exit 1
fi
