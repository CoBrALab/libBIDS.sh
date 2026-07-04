#!/usr/bin/env bash

set -euo pipefail

# Avoid matching current dir during glob tests if it isn't expected
shopt -u nullglob

# shellcheck disable=SC1091
source "libBIDS.sh"

# Simple test runner
tests_run=0
tests_passed=0
tests_failed=0

run_test() {
  local name="$1"
  local func="$2"

  tests_run=$((tests_run + 1))
  echo "Running $name..."
  if $func; then
    echo "  [PASS]"
    tests_passed=$((tests_passed + 1))
  else
    echo "  [FAIL]"
    tests_failed=$((tests_failed + 1))
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-}"

  if [[ "$expected" != "$actual" ]]; then
    echo "    Assertion failed: $msg"
    echo "      Expected: '$expected'"
    echo "      Actual:   '$actual'"
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
  local bids_dir="bids-examples/ds001"
  local table
  table=$(libBIDSsh_parse_bids_to_table "$bids_dir")

  assert_contains "sub-01" "$table" "table should contain sub-01" || return 1
  assert_contains "task-balloonanalogrisktask" "$table" "table should contain task-balloonanalogrisktask" || return 1

  # Check header
  local header
  header=$(head -n 1 <<<"$table")
  assert_contains "sub" "$header" "header should contain sub" || return 1
  assert_contains "task" "$header" "header should contain task" || return 1
  assert_contains "path" "$header" "header should contain path" || return 1

  # Verify size roughly (this is a known dataset)
  local row_count
  row_count=$(wc -l <<<"$table")
  if ((row_count < 10)); then
    echo "    Assertion failed: dataset parsed seems too small ($row_count rows)"
    return 1
  fi
  return 0
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

test_extension_json_rows_to_column_json_path() {
  local table="extension	path	sub
nii.gz	/path/to/data.nii.gz	sub-1
json	/path/to/data.json	sub-1
nii.gz	/path/to/other.nii.gz	sub-2"

  local updated
  updated=$(libBIDSsh_extension_json_rows_to_column_json_path "$table")

  assert_contains "json_path" "$updated" "should add json_path column" || return 1
  assert_contains "/path/to/data.json" "$updated" "should map json path to nii.gz row" || return 1
  assert_contains "NA" "$updated" "sub-2 should have NA for json_path" || return 1

  return 0
}

test_table_column_to_array() {
  local table="sub	ses
sub-01	ses-1
sub-01	ses-2
sub-02	ses-1"

  declare -a subjects
  libBIDSsh_table_column_to_array "$table" "sub" subjects true true
  assert_equals "2" "${#subjects[@]}" "should have 2 unique subjects" || return 1
  assert_equals "sub-01" "${subjects[0]}" "first should be sub-01" || return 1
  assert_equals "sub-02" "${subjects[1]}" "second should be sub-02" || return 1

  return 0
}

test_table_iterator() {
  local table="sub	ses
sub-01	ses-1
sub-02	ses-2"

  declare -A row
  local count=0
  local subj_str=""
  while libBIDSsh_table_iterator "$table" row "sub"; do
    count=$((count + 1))
    subj_str="${subj_str}${row[sub]} "
  done

  assert_equals "2" "$count" "should iterate 2 times" || return 1
  assert_equals "sub-01 sub-02 " "$subj_str" "should extract sub values" || return 1
  return 0
}

test_json_to_associative_array() {
  local json_file="bids-examples/ds001/dataset_description.json"
  if [[ ! -f "$json_file" ]]; then
    echo "    Skip: $json_file not found"
    return 1 # Fails if we don't have the submodule checked out
  fi

  declare -A json_data
  libBIDSsh_json_to_associative_array "$json_file" json_data

  assert_equals "string" "${json_data[BIDSVersion]%\:*}" "BIDSVersion should be present as string" || return 1
  assert_equals "string" "${json_data[Name]%\:*}" "Name should be present as string" || return 1
  return 0
}

# Build a small self-contained BIDS-shaped fixture with a .bidsignore.
# Echoes the temp directory path; caller is responsible for removing it.
_make_bidsignore_fixture() {
  local root
  root=$(mktemp -d)
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
  root=$(mktemp -d)
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
  _chk ".git/config" 0 "default ignore: .git**"                                  # ignored

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

echo "Starting libBIDS.sh test suite..."
echo "---"

run_test "Internal: _libBIDSsh_parse_filename" test_parse_filename
run_test "Internal: _libBIDSsh_parse_filename datatype/derivatives" test_parse_filename_datatype_derivatives
run_test "Public API: libBIDSsh_parse_bids_to_table" test_parse_bids_to_table
run_test "Public API: libBIDSsh_table_filter" test_table_filter
run_test "Public API: libBIDSsh_drop_na_columns" test_drop_na_columns
run_test "Public API: libBIDSsh_extension_json_rows_to_column_json_path" test_extension_json_rows_to_column_json_path
run_test "Public API: libBIDSsh_table_column_to_array" test_table_column_to_array
run_test "Public API: libBIDSsh_table_iterator" test_table_iterator
run_test "Public API: libBIDSsh_json_to_associative_array" test_json_to_associative_array
run_test "Internal: _libBIDSsh_path_is_ignored (.bidsignore matcher)" test_bidsignore_matcher
run_test "Public API: libBIDSsh_parse_bids_to_table .bidsignore" test_bidsignore_parser
run_test "Public API: libBIDSsh_apply_bidsignore" test_apply_bidsignore

echo "---"
echo "Test summary:"
echo "Executed: $tests_run"
echo "Passed:   $tests_passed"
echo "Failed:   $tests_failed"

if ((tests_failed > 0)); then
  exit 1
fi
