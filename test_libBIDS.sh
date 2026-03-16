#!/usr/bin/env bash

set -euo pipefail

# Avoid matching current dir during glob tests if it isn't expected
shopt -u nullglob

# Source the library
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

test_parse_bids_to_table() {
  local bids_dir="bids-examples/ds001"
  local table
  table=$(libBIDSsh_parse_bids_to_table "$bids_dir")
  
  assert_contains "sub-01" "$table" "table should contain sub-01" || return 1
  assert_contains "task-balloonanalogrisktask" "$table" "table should contain task-balloonanalogrisktask" || return 1
  
  # Check header
  local header
  header=$(head -n 1 <<< "$table")
  assert_contains "sub" "$header" "header should contain sub" || return 1
  assert_contains "task" "$header" "header should contain task" || return 1
  assert_contains "path" "$header" "header should contain path" || return 1
  
  # Verify size roughly (this is a known dataset)
  local row_count=$(wc -l <<< "$table")
  if (( row_count < 10 )); then
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
  local subjects=""
  while libBIDSsh_table_iterator "$table" row "sub"; do
    count=$((count + 1))
    subjects="${subjects}${row[sub]} "
  done
  
  assert_equals "2" "$count" "should iterate 2 times" || return 1
  assert_equals "sub-01 sub-02 " "$subjects" "should extract sub values" || return 1
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

echo "Starting libBIDS.sh test suite..."
echo "---"

run_test "Internal: _libBIDSsh_parse_filename" test_parse_filename
run_test "Public API: libBIDSsh_parse_bids_to_table" test_parse_bids_to_table
run_test "Public API: libBIDSsh_table_filter" test_table_filter
run_test "Public API: libBIDSsh_drop_na_columns" test_drop_na_columns
run_test "Public API: libBIDSsh_extension_json_rows_to_column_json_path" test_extension_json_rows_to_column_json_path
run_test "Public API: libBIDSsh_table_column_to_array" test_table_column_to_array
run_test "Public API: libBIDSsh_table_iterator" test_table_iterator
run_test "Public API: libBIDSsh_json_to_associative_array" test_json_to_associative_array

echo "---"
echo "Test summary:"
echo "Executed: $tests_run"
echo "Passed:   $tests_passed"
echo "Failed:   $tests_failed"

if (( tests_failed > 0 )); then
  exit 1
fi
