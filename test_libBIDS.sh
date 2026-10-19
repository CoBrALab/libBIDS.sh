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
run_test "Public API: libBIDSsh_table_filter patterns and --invert" test_table_filter_patterns
run_test "Public API: libBIDSsh_table_filter --invert complement (ds001)" test_table_filter_invert_complement
run_test "Public API: libBIDSsh_table_filter column errors" test_table_filter_columns
run_test "Public API: libBIDSsh_table_filter on POSIX awk" test_table_filter_posix_awk
run_test "Bash 4.3: empty arrays under set -u" test_empty_arrays_nounset
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
echo "Skipped:  $tests_skipped"

if ((tests_failed > 0)); then
  exit 1
fi
