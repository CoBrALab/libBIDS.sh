# libBIDS.sh

A Bash library for parsing and processing BIDS datasets into TSV (tab-separated values) structures, enabling flexible data filtering, extraction, and iteration within shell scripts.

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

macOS users: Apple's default Bash (3.2) is too old. You must upgrade to ≥ 4.3.

See: https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx

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

## Core Functions

### `libBIDSsh_parse_bids_to_table`

Parses a directory tree, identifies BIDS files, extracts BIDS entities, and outputs TSV.

```bash
table_data=$(libBIDSsh_parse_bids_to_table "bids-examples/ds001")
```

**Output columns:**

The TSV columns use the full BIDS entity names (display names), not the short keys found in filenames.

- `derivatives`: Pipeline name if in derivatives folder
- `data_type`: BIDS data type (anat, func, dwi, etc.)
- BIDS entities: `subject` (not sub), `session` (not ses), `task`, `acquisition` (not acq), `run`, etc.
- `suffix`: File suffix (bold, T1w, dwi, etc.)
- `extension`: File extension
- `path`: Full file path

**Note:** When filtering or accessing columns, always use these full names (e.g., `subject`, `session`, `acquisition`).

## Filtering and Subsetting

### `libBIDSsh_table_filter`

Filters TSV data by columns, values, regex, and missing data.

```bash
libBIDSsh_table_filter "${table_data}" [OPTIONS]
```

**Options:**

- `-c, --columns <col1,col2,...>`: Select columns by name or index (tab-separated)
- `-r, --row-filter <col:pattern>`: Keep rows where column matches value/regex (AND logic for multiple filters)
- `-d, --drop-na <col1,col2,...>`: Drop rows where listed columns are "NA" (tab-separated)

**Examples:**

```bash
# Keep only subject and task columns
libBIDSsh_table_filter "$table_data" -c $'subject\ttask'

# Filter for balloon analog risk task (ds001)
libBIDSsh_table_filter "$table_data" -r "task:balloonanalogrisktask"

# Multiple filters: task AND subject 01
libBIDSsh_table_filter "$table_data" -r "task:balloonanalogrisktask" -r "subject:sub-01"

# Complex filtering with regex
libBIDSsh_table_filter "$table_data" -r "task:(rest|motor)" -r "run:[1-3]"
```

### `libBIDSsh_drop_na_columns`

Removes columns that contain only NA values across all rows.

```bash
cleaned_table=$(libBIDSsh_drop_na_columns "$table_data")
```

**Example:**

```bash
# Remove empty columns from dataset
table_data=$(libBIDSsh_parse_bids_to_table "bids-examples/ds001")
cleaned_table=$(libBIDSsh_drop_na_columns "$table_data")
```

## JSON Processing

### `libBIDSsh_extension_json_rows_to_column_json_path`

Processes TSV data to add a `json_path` column that links data files to their **direct** JSON sidecars.
Note: This only matches files where a JSON file exists with the exact same name (except extension). It does not resolve BIDS inheritance.

```bash
updated_table=$(libBIDSsh_extension_json_rows_to_column_json_path "$table_data")
```

**Behavior:**

- Matches JSON files to corresponding data files based on BIDS entities
- Drops JSON rows that have matching data files
- Keeps unmatched JSON files with their path in `json_path`
- Adds `NA` for data files without direct JSON sidecars

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

**Value format:**
- `type:value` for primitives (e.g., `string:hello`, `number:42`)
- `array:item1,item2,item3` for arrays
- `object:{json_string}` for nested objects

**Example:**

```bash
declare -A sidecar
libBIDSsh_json_to_associative_array "bids-examples/volume_timing/sub-01/func/sub-01_task-rest_acq-dense_bold.json" sidecar
echo "TR: ${sidecar[RepetitionTime]}"  # Output: number:2
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

### `libBIDS_table_iterator`

Iterates TSV rows, exposes fields in an associative array with optional sorting.

```bash
while libBIDS_table_iterator "$table_data" row_var [sort_col1] [sort_col2] [-r]; do
  # Process row
done
```

**Arguments:**
- `table_data`: TSV data string
- `row_var`: Name of associative array to populate with each row. Keys correspond to column headers (e.g., `row[subject]`).
- `sort_columns`: Optional column names to sort by
- `-r`: Optional reverse sort flag

**Example:**

```bash
declare -A row
while libBIDS_table_iterator "$table_data" row "subject" "session" "run"; do
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

- Individual BIDS entities using short keys (`sub`, `ses`, `task`, `acq`, etc.)
- `suffix`: File suffix
- `extension`: File extension
- `data_type`: Inferred data type
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
  -r "data_type:func" \
  -r "suffix:bold")

# Add JSON paths
func_table=$(libBIDSsh_extension_json_rows_to_column_json_path "$func_table")

# Process each file with its JSON metadata
declare -A row
while libBIDS_table_iterator "$func_table" row "subject" "task" "run"; do
  echo "Processing: ${row[path]}"

  if [[ "${row[json_path]}" != "NA" ]]; then
    declare -A json_data
    libBIDSsh_json_to_associative_array "${row[json_path]}" json_data
    echo "  TR: ${json_data[RepetitionTime]:-NA}"
    echo "  Task: ${json_data[TaskName]:-NA}"
  fi
done
```

## Customization

### Adding non-BIDS entities 

If your dataset uses an entity that is not part of the official BIDS specification, you can include them in the parsing logic via JSON file(s) in the `custom` directory:

```json
{
  "entities": [
    {
      "name": "foo",
      "display_name": "fooval",
      "pattern": "*(_foo-+([a-zA-Z0-9]))"
    },
    {
      "name": "bar",
      "display_name": "baridx",
      "pattern": "*(_bar-+([0-9]))"
    }
    ...
  ]
}
```

To see an example, rename the template file from `custom/custom_entities.json.tpl` to `custom/custom_entities.json`.

## Notes

- All functions handle TSV data as strings, not files
- NA values are used for missing BIDS entities
- Pattern matching is permissive and may match non-BIDS-compliant files
- JSON processing requires `jq` to be installed
- Sort operations use version sort for natural ordering of numbers
- Column lists for filtering should use tab-separated values (e.g., `$'subject\ttask'`)