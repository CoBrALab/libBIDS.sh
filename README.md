# libBIDS.sh

A Bash library for parsing and processing BIDS datasets into TSV-like structures, enabling flexible data filtering, extraction, and iteration within shell scripts.

Pattern matching is permissive with respect to BIDS spec, it may match some files which do not meet validation requirements.

## Features

- Converts BIDS datasets into a flat TSV format
- Extracts key BIDS entities from filenames
- Provides filtering, column selection, and row operations
- Allows iteration over rows with associative arrays
- Handles JSON sidecar files and metadata
- Designed for shell scripting in pipelines and automation

## Requirements

- **Bash version:** ≥ 4.3
  (Due to associative arrays, `readarray`, and `declare -n` usage)
- **`find` and `sort`** with `-print0` and `-z` (GNU or BSD versions)

macOS users: Apple's default Bash (3.2) is too old. You must upgrade to ≥ 4.3.

See: https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx

## Testing

The test datasets come from the
[bids-examples](https://github.com/bids-standard/bids-examples) repository, which
is a git submodule at `bids-examples/`. Clone with the submodule, then run the
unit test suite (you can run it from any directory):

```bash
git clone --recurse-submodules https://github.com/CoBrALab/libBIDS.sh
cd libBIDS.sh
./test_libBIDS.sh
```

Each assertion that fails, and each command that fails, makes its test fail.
If the submodule is missing, the suite stops with an error that tells you to
run `git submodule update --init`. The JSON test is skipped if `jq` is not
installed.

GitHub Actions (`.github/workflows/tests.yml`) runs the unit tests, parses every
bids-examples dataset, and runs `shellcheck` for each push to `master` and for
each pull request.

Bash 4.3 is the minimum version. If you have a bash 4.3 binary, also run the
suite with it (for example `/path/to/bash-4.3 ./test_libBIDS.sh`). Bash before
4.4 stops with "unbound variable" on an empty array expansion under `set -u`,
and newer Bash versions do not show this problem. CI runs the suite with bash 4.3
too.

## Usage

### Sourcing the Library

Include the library in your script:

```bash
source libBIDS.sh
```

### Command-Line Execution

Run directly to dump dataset as TSV:

```bash
./libBIDS.sh bids-examples/ds001
```

Usage: `./libBIDS.sh [--no-bidsignore|--no-default-ignores] [--] <dir>`.
The options are the same as for `libBIDSsh_parse_bids_to_table`. Use `-h` or
`--help` to show the usage (on stdout, exit status 0). With no argument, the
script writes an error and the usage to stderr and exits with status 1.

## Core Functions

### `libBIDSsh_parse_bids_to_table`

Parses a directory tree, identifies BIDS files, extracts BIDS entities, and outputs TSV.

```bash
table_data=$(libBIDSsh_parse_bids_to_table "bids-examples/ds001")
```

**Options:**

- `--no-bidsignore`: Do not honor the dataset's `.bidsignore` file or the built-in default ignores (parse every BIDS-shaped file).
- `--no-default-ignores`: Honor the dataset's `.bidsignore` but skip the built-in default ignores (`/sourcedata/`, `/code/`, `/stimuli/`, `/log/`, `/doc/` at the dataset root, and dotfiles `.**`).

By default the parser honors a root-level `.bidsignore` and the built-in default
ignores (see [`.bidsignore` support](#bidsignore-support) below).

**Which files are in the table:**

- A file or directory is a row when its name is `<anything>_<suffix><extension>`,
  where `<suffix>` and `<extension>` are values from the BIDS schema. Entity
  tokens in the name are not checked (permissive matching).
- The parser follows symbolic links to directories (for example a `sub-02` link to
  other storage). A link loop is reported by `find` on stderr and is not followed.
- Files and directories whose name starts with `.` are skipped.
- Rows are sorted by path, in the collation order of the current locale.

**Output columns:**

The TSV columns use the full BIDS entity **names** (e.g. `subject`), not the entity
**keys** (the short tokens like `sub` found in filenames). In BIDS schema terms the
key is the entity's `.name` field (`sub`) and the column header is the entity object
name (`subject`).

- `derivatives`: Pipeline name if in derivatives folder
- `datatype`: BIDS datatype (anat, func, dwi, etc.)
- BIDS entities: `subject` (key `sub`), `session` (key `ses`), `task`, `acquisition` (key `acq`), `run`, etc.
- `suffix`: File suffix (bold, T1w, dwi, etc.)
- `extension`: File extension
- `path`: Full file path

**Note:** When filtering or accessing columns, always use these entity names (e.g., `subject`, `session`, `acquisition`).

## Filtering and Subsetting

### `libBIDSsh_table_filter`

Filters table data by columns, values, regex, and missing data.

```bash
libBIDSsh_table_filter "${table_data}" [OPTIONS]
```

**Options:**

- `-c, --columns <col1,col2,...>`: Select columns by name or 1-based index, in the given order
- `-r, --row-filter <col:pattern>`: Keep rows where column matches pattern (AND logic for multiple filters).
  The pattern is an unanchored AWK extended regex (substring match). Only the first `:` separates the
  column from the pattern. Values carry the entity key prefix (`sub-01`, `run-01`), so use
  `^...$` anchors for an exact match: `subject:sub-01` also matches `sub-010`.
- `-v, --invert`: Invert row filter - remove the rows that match all `-r` filters, keep all other rows
- `-d, --drop-na <col1,col2,...>`: Drop rows where listed columns are "NA"

A column name must be an exact header name (no spaces, no empty entries); with duplicate header
names the first column is used. An unknown name, index 0, an index larger than the column count,
or an option without its argument prints an error to stderr and returns 1 with no output.
The filter uses POSIX awk only, so it runs on gawk, mawk and BSD awk.

**Examples:**

```bash
# Keep only subject and task columns
libBIDSsh_table_filter "$table_data" -c "subject,task"

# Filter for balloon analog risk task (ds001)
libBIDSsh_table_filter "$table_data" -r "task:balloonanalogrisktask"

# Multiple filters: task AND exactly subject 01
libBIDSsh_table_filter "$table_data" -r "task:balloonanalogrisktask" -r "subject:^sub-01$"

# Complex filtering with regex (runs 1 to 3 only)
libBIDSsh_table_filter "$table_data" -r "task:(rest|motor)" -r "run:^run-0?[1-3]$"

# A literal dot needs a backslash
libBIDSsh_table_filter "$table_data" -r 'extension:^nii\.gz$'

# Remove all bold files (invert filter)
libBIDSsh_table_filter "$table_data" -r "suffix:bold" --invert
```

### `libBIDSsh_drop_na_columns`

Removes columns that contain only NA values across all rows.
The header sets the number of columns. Empty lines (for example a trailing
newline) are ignored. A field that a short row does not have counts as NA.
A header-only table (no data rows) is returned unchanged.

```bash
cleaned=$(libBIDSsh_drop_na_columns "$table_data")
```

**Example:**

```bash
# Remove empty columns from dataset
table_data=$(libBIDSsh_parse_bids_to_table "bids-examples/ds001")
cleaned=$(libBIDSsh_drop_na_columns "$table_data")
```

## `.bidsignore` support

A BIDS dataset may carry a root-level [`.bidsignore`](https://bids-specification.readthedocs.io/en/stable/derivatives/introduction.html#bidsignore)
file listing **gitignore-style patterns** for files that are not part of the BIDS
standard. `libBIDSsh_parse_bids_to_table` honors it by default and also applies a
built-in list of default ignores, based on the defaults of `bids-validator`
(`src/files/ignore.ts`).

**Built-in default ignores:** `/sourcedata/`, `/code/`, `/stimuli/`, `/log/`,
`/doc/`, `.**` (dotfiles and dot-directories at any depth) and `!/.bidsignore`.
The directory patterns are anchored to the dataset root, so directories with the
same name below the root (for example `derivatives/<pipeline>/code/`,
`derivatives/<pipeline>/sourcedata/` or `sub-01/log/`) are **not** ignored.
Differences from `bids-validator`:

- `derivatives/` is intentionally **not** ignored — libBIDS.sh treats derivatives
  as first-class data.
- `bids-validator` does not look inside dotfile paths at all ("prune"). libBIDS.sh
  treats `.**` as an ordinary pattern, so a later `!` line in `.bidsignore` can
  re-include a path below a dot-directory.
- The BIDS schema marks `docs/` and `logs/` as opaque directories, but
  `bids-validator` (and libBIDS.sh) ignores `doc/` and `log/`. Add `/docs/` or
  `/logs/` to `.bidsignore` if a dataset uses them.

**Supported gitignore syntax:** blank lines and `#` comments; `*` and `?` (which do
not cross `/`); `**` whole-segment globstar (crosses directories); `[...]` bracket
expressions; `\`-escapes; leading/embedded `/` to anchor a pattern to the dataset
root; trailing `/` for directory-only matches; and `!` negation (re-include) with
last-match-wins ordering.

**Limitations:** only the root-level `.bidsignore` is read (no inheritance / nested
files, matching `bids-validator`). Because the parser only ever globs files whose
suffix and extension are valid BIDS tokens, `.bidsignore` patterns that target
non-BIDS files (e.g. `*.html`) are effectively no-ops — the parser never picked
those files up. `.bidsignore` becomes meaningful for BIDS-shaped files an author
explicitly excludes (e.g. `**/sub-*_..._FLASH.nii.gz`).

```bash
# Honor .bidsignore + defaults (the default behavior)
table_data=$(libBIDSsh_parse_bids_to_table "path/to/dataset")

# Parse everything, ignoring .bidsignore entirely
raw=$(libBIDSsh_parse_bids_to_table --no-bidsignore "path/to/dataset")

# Honor .bidsignore but keep sourcedata/, code/, etc.
table_data=$(libBIDSsh_parse_bids_to_table --no-default-ignores "path/to/dataset")
```

### `libBIDSsh_apply_bidsignore`

Applies a dataset's `.bidsignore` (and, by default, the built-in default ignores) to
an already-parsed table, dropping rows whose file is excluded. Useful for filtering
a table that was parsed with `--no-bidsignore`, or one obtained from another source.

```bash
filtered=$(libBIDSsh_apply_bidsignore "$table_data" "path/to/dataset" [--no-default-ignores])
```

**Example:**

```bash
raw=$(libBIDSsh_parse_bids_to_table --no-bidsignore "path/to/dataset")
# ... inspect or process the unfiltered table ...
filtered=$(libBIDSsh_apply_bidsignore "$raw" "path/to/dataset")
```

## JSON Processing

### `libBIDSsh_extension_json_rows_to_column_json_path`

Processes table data to add a `json_path` column that links data files to their **direct** JSON sidecars.
Note: This only matches files where a JSON file exists with the exact same name (except extension). It does not resolve BIDS inheritance.

```bash
updated=$(libBIDSsh_extension_json_rows_to_column_json_path "$table_data")
```

**Behavior:**

- Matches JSON files to corresponding data files based on BIDS entities
- Drops JSON rows that have matching data files
- Keeps unmatched JSON files with their path in `json_path`
- Adds `NA` for data files without direct JSON sidecars
- Ignores empty lines (for example a trailing newline)
- Returns the table unchanged if it already has a `json_path` column, so a second call has no effect

**Example:**

```bash
table_data=$(libBIDSsh_parse_bids_to_table "bids-examples/ds001")
table_with_json=$(libBIDSsh_extension_json_rows_to_column_json_path "$table_data")
```

### `libBIDSsh_json_to_associative_array`

Parses a JSON file into a bash associative array with type information.

```bash
declare -A json_data
libBIDSsh_json_to_associative_array "file.json" json_data
```

The function clears the target array before it adds the keys of the file.
It returns 1 and writes a message to stderr if `jq` is missing, if the file
is not valid JSON, if the top-level value is not an object, or if `jq` fails.
On error, the target array is empty. It also returns 1 if the target is not
an associative array (`declare -A`). Keys and values can contain `=`, quotes
and newlines. A NUL character (`\u0000`) in a key, a string or an array item
is removed. A key that is an empty string is skipped with a warning.

**Value format:**
- `type:value` for primitives (e.g., `string:hello`, `number:42`,
  `boolean:true`, `null:null`)
- `array:item1,item2,item3` for arrays. A `null` item is empty, and an item
  that is an array or an object is JSON text (e.g., `[{"a":1}]` gives
  `array:{"a":1}`).
- `object:{json_string}` for nested objects

The array format is not reversible: items are joined with `,` and are not
escaped. Thus `["Doe, J", "Smith, A"]` and `["Doe", " J", "Smith", " A"]` both
give `array:Doe, J,Smith, A`, and `[null]` and `[""]` both give `array:`. If you
need the exact items, read the file with `jq` directly.

**Example:**

```bash
declare -A sidecar
libBIDSsh_json_to_associative_array "bids-examples/volume_timing/sub-01/func/sub-01_task-rest_acq-dense_bold.json" sidecar
echo "TR: ${sidecar[RepetitionTime]}"  # Output: number:1
```

## Column Extraction

### `libBIDSsh_table_column_to_array`

Extracts a column as a Bash array with deduplication and NA filtering.

```bash
libBIDSsh_table_column_to_array "$table_data" "column" array_var [unique] [exclude_NA]
```

**Arguments:**

- `table_data`: TSV-formatted string
- `column`: Column name (e.g., `subject`) or index
- `array_var`: Name of array variable to populate
- `unique`: "true" (default) to return only unique values
- `exclude_NA`: "true" (default) to exclude NA values

**Returns:** 0 on success, also when no values remain (for example, a column
that has only `NA` values gives an empty array). 1, with an error on stderr,
when the column is not in the header or the index is not in 1 to the number of
columns. Array names that start with `_libbidssh_c2a_` are reserved.

**Example:**

```bash
declare -a subjects
# Note: Use "subject", not "sub"
libBIDSsh_table_column_to_array "$table_data" "subject" subjects true true
echo "Unique subjects: ${subjects[@]}"

declare -a all_runs
libBIDSsh_table_column_to_array "$table_data" "run" all_runs false false
echo "All runs (including duplicates and NA): ${all_runs[@]}"
```

## Row Iteration

### `libBIDSsh_table_iterator`

Iterates table rows in sorted order and exposes the fields of each row in an associative array.

```bash
while libBIDSsh_table_iterator "$table_data" row_var [sort_col1] [sort_col2] [-r]; do
  # Process row
done
```

**Arguments:**
- `table_data`: Table data string
- `row_var`: Name of associative array to populate with each row. Keys are the column headers only (e.g., `row[subject]`).
- `sort_columns`: Optional column names to sort by. If you give no sort columns, rows are sorted by all columns, left to right. Rows are always sorted (`sort --version-sort`); the table order is not kept.
- `-r`: Optional reverse sort flag

**Returns:** 0 while rows remain, 1 when done. You can also call the function outside of a `while` loop (for example, to read only the first row). A call after the last row returns 1, so check its status or append `|| true` when `set -e` is on.

**State:** The first call sorts the table one time and keeps the sorted rows and the cursor in internal `_LIBBIDSSH_ITER_*` arrays, keyed by the name of `row_var`. The cursor is not stored in `row_var`. A call with a different table or different sort arguments starts a new iteration. After the last row, the state is removed, so the next loop starts from the first row. After a `break`, a new loop with the same array, table and sort arguments continues after the last row it returned. To start again from the first row, empty the array (`row=()`) or call the function once with an empty table (`libBIDSsh_table_iterator "" row || true`). A new array (for example `local -A row` in a function) also starts from the first row. Do not use `unset row` alone as a reset, because the next call then fails; if you unset the array, declare it again (`declare -A row`). An inner loop that runs while an outer loop is active must use a different array name, because the state is keyed by the array name. Do not change the table string inside the loop body, because a changed table starts again from the first row. After a `break`, the state (a copy of the table and its sorted rows) stays in memory until the next call with that array name or a reset. Row array names that start with `_lbit_` are reserved and give an error. Empty fields (two adjacent tabs) stay in their column. Each call gets the table by value and compares it with the saved table, so each call still takes time in proportion to the table size.

**Example:**

```bash
declare -A row
while libBIDSsh_table_iterator "$table_data" row "subject" "session" "run"; do
  echo "Processing: ${row[subject]} ${row[session]} ${row[run]}: ${row[path]}"
done
```

## Internal Functions

### `_libBIDSsh_parse_filename`

Internal function that parses BIDS filenames into component entities.

```bash
declare -A file_info
_libBIDSsh_parse_filename "sub-01_task-rest_bold.nii.gz" file_info
```

**Populated fields:**

- Individual BIDS entities using entity keys (`sub`, `ses`, `task`, `acq`, etc.)
- `suffix`: File suffix
- `extension`: File extension
- `datatype`: Inferred datatype
- `derivatives`: Pipeline name if applicable
- `path`: Full path
- `_key_order`: Order of keys for iteration

## Complete Examples

### Basic Dataset Processing

```bash
#!/usr/bin/env bash
source libBIDS.sh

bids_path="bids-examples/ds001"
table_data=$(libBIDSsh_parse_bids_to_table "$bids_path")

# Extract unique subjects
declare -a subjects
libBIDSsh_table_column_to_array "$table_data" "subject" subjects true true
echo "Found subjects: ${subjects[*]}"

# Clean up empty columns
table_data=$(libBIDSsh_drop_na_columns "$table_data")

# Add JSON sidecar information (if sidecars match exactly)
table_data=$(libBIDSsh_extension_json_rows_to_column_json_path "$table_data")
```

### Functional Data Processing

```bash
#!/usr/bin/env bash
source libBIDS.sh

# Using volume_timing dataset which has sidecars
bids_path="bids-examples/volume_timing"
table_data=$(libBIDSsh_parse_bids_to_table "$bids_path")

# Filter for functional BOLD data
func_table=$(libBIDSsh_table_filter "$table_data" \
  -r "datatype:func" \
  -r "suffix:bold")

# Add JSON paths
func_table=$(libBIDSsh_extension_json_rows_to_column_json_path "$func_table")

# Process each file with its JSON metadata
declare -A row
while libBIDSsh_table_iterator "$func_table" row "subject" "task" "run"; do
  echo "Processing: ${row[path]}"

  if [[ "${row[json_path]}" != "NA" ]]; then
    declare -A json_data
    # The array is cleared on each call, so no values stay from the last file.
    libBIDSsh_json_to_associative_array "${row[json_path]}" json_data
    echo "  TR: ${json_data[RepetitionTime]:-NA}"
    # TaskName is in the inherited sidecar task-rest_bold.json at the dataset
    # root. json_path is only the sidecar with the same name, so this is NA.
    echo "  Task: ${json_data[TaskName]:-NA}"
  fi
done
```

## Customization

### Adding non-BIDS entities 

If your dataset uses an entity that is not part of the official BIDS specification, you can include them in the parsing logic via JSON file(s) in the `custom` directory next to the real `libBIDS.sh` file (a symlink to `libBIDS.sh` is resolved). Each entity object uses `key` (the short filename token, required) and `name` (the long column header, required). Each custom entity adds one column after the standard entity columns. The optional `pattern` field (a bash extended-glob) is not used for matching: the parser selects files by suffix and extension only, and then reads every `<key>-<value>` token from the filename:

```json
{
  "entities": [
    {
      "key": "foo",
      "name": "fooval",
      "pattern": "*(_foo-+([a-zA-Z0-9]))"
    },
    {
      "key": "bar",
      "name": "baridx",
      "pattern": "*(_bar-+([0-9]))"
    }
    ...
  ]
}
```

To see an example, rename the template file from `custom/custom_entities.json.tpl` to `custom/custom_entities.json`.

A `key` or `name` that is the same as a standard BIDS entity, a fixed column (`derivatives`, `datatype`, `suffix`, `extension`, `path`, `json_path`) or an earlier custom entity is skipped with a warning to stderr. A JSON file that is not valid, or that has no `entities` array, is an error: `libBIDSsh_parse_bids_to_table` writes the file name to stderr and returns 1.

## Notes

- All functions handle table data as strings, not files
- NA values are used for missing BIDS entities
- Pattern matching is permissive and may match non-BIDS-compliant files
- JSON processing requires `jq` to be installed
- Sort operations use version sort for natural ordering of numbers