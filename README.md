# libBIDS.sh

A bash library used to parse BIDS datasets into a data structure suitable for use in shell pipelines.

Parses a BIDS dataset by:

1. Using bash `extglob` features to find all BIDS-compliant filenames
2. Parsing out the potential subfields of the BIDS file naming scheme into a key-value pairs
3. Constructs a "database" CSV-structured representation of the dataset
4. Provides library functions to subset the database based on the fields
5. Provides functions to iterate over the dataset

Implementation is "permissive" with regards to the BIDS spec, some combinations of optional fields are allowed in
the parser that the BIDS spec does not allow.

## Dependencies

libBIDS.sh uses POSIX as well as bash functionality. The minimum version of bash supported is 4.3.

Sorry Mac users, you'll need to upgrade the 18-year-old bash version (3.2, 2007) that Apple ships in OSX.
https://apple.stackexchange.com/questions/193411/update-bash-to-version-4-0-on-osx

## Usage

libBIDS.sh has two use cases:

1. `source libBIDS.sh` in your bash scripts to provide the functions for parsing BIDS data structures
2. Run `libBIDS.sh /path/to/bids/dataset` to output a CSV-formatted representation of the BIDS dataset

## Available Functions

### Core Dataset Parsing

#### `libBIDSsh_parse_bids_to_csv`
Parses a BIDS dataset and returns a CSV representation with columns for all BIDS entities.

**Usage:**
```bash
csv_data=$(libBIDSsh_parse_bids_to_csv "/path/to/bids/dataset")
```

**Output columns:**
- `sub`, `ses`, `task`, `acq`, `ce`, `rec`, `dir`, `run`, `recording`, `mod`, `echo`, `part`, `chunk`
- `suffix`, `extension`, `type`, `derivatives`, `filename`, `path`

### Data Filtering and Subsetting

#### `libBIDSsh_csv_filter`
Filters CSV-structured BIDS data, returning specified columns and optionally filtering by row content.

**Usage:**
```bash
libBIDSsh_csv_filter "${csv_data}" [options]
```

**Options:**
- `-c, --columns <list>`: Comma-separated list of column indices or column names to keep
- `-r, --row-filter <col:pattern>`: Filter rows where column matches exact string or regex pattern (multiple filters combined with AND)
- `-d, --drop-na <list>`: Drop rows where any of the specified columns contain "NA"

**Examples:**
```bash
# Get only subject and task columns
filtered=$(libBIDSsh_csv_filter "${csv_data}" -c "sub,task")

# Filter for specific task and run
filtered=$(libBIDSsh_csv_filter "${csv_data}" -r "task:rest" -r "run:1")

# Remove rows with missing session information
filtered=$(libBIDSsh_csv_filter "${csv_data}" -d "ses")

# Combine multiple operations
filtered=$(libBIDSsh_csv_filter "${csv_data}" -c "sub,ses,task" -r "task:rest" -d "ses")
```

### Data Extraction and Conversion

#### `libBIDSsh_csv_column_to_array`
Converts a column from CSV data to a bash array, with options for uniqueness and NA handling.

**Usage:**
```bash
declare -a my_array
libBIDSsh_csv_column_to_array "${csv_data}" "column_name" my_array [unique] [exclude_NA]
```

**Parameters:**
- `csv_data`: The CSV data string
- `column_name`: Name or index of the column to extract
- `array_ref`: Name of the array variable to populate
- `unique`: (optional, default: true) Remove duplicate entries
- `exclude_NA`: (optional, default: true) Exclude "NA" values

**Example:**
```bash
declare -a subjects
libBIDSsh_csv_column_to_array "${csv_data}" "sub" subjects true true
echo "Found subjects: ${subjects[@]}"
```

### Data Iteration

#### `libBIDS_csv_iterator`
Iterates through CSV data row by row, returning each row as key-value pairs in an associative array. Supports optional sorting.

**Usage:**
```bash
declare -A row_data
while libBIDS_csv_iterator "${csv_data}" row_data [sort_column1] [sort_column2] ...; do
    # Process each row
    echo "Subject: ${row_data[sub]}, Task: ${row_data[task]}"
done
```

**Parameters:**
- `csv_data`: The CSV data string
- `row_data`: Name of associative array to populate with row data
- `sort_columns`: (optional) Column names to sort by before iteration

**Example:**
```bash
declare -A row
while libBIDS_csv_iterator "${csv_data}" row "sub" "ses" "run"; do
    echo "Processing: ${row[filename]}"
    echo "  Subject: ${row[sub]}"
    echo "  Session: ${row[ses]}"
    echo "  Task: ${row[task]}"
done
```

## Complete Example

```bash
#!/bin/bash
source libBIDS.sh

# Parse BIDS dataset
bids_path="/path/to/bids/dataset"
csv_data=$(libBIDSsh_parse_bids_to_csv "${bids_path}")

# Get all unique subjects
declare -a subjects
libBIDSsh_csv_column_to_array "${csv_data}" "sub" subjects

echo "Found ${#subjects[@]} subjects: ${subjects[*]}"

# Filter for functional data only
func_data=$(libBIDSsh_csv_filter "${csv_data}" -r "type:func" -c "sub,ses,task,run,filename")

# Iterate through functional files, sorted by subject and session
declare -A row
while libBIDS_csv_iterator "${func_data}" row "sub" "ses"; do
    echo "Processing: ${row[filename]}"
    # Your processing logic here
done
```

## Supported BIDS Entities

The parser recognizes the following BIDS entities and file types:

**Entities:** sub, ses, task, acq, ce, rec, dir, run, recording, mod, echo, part, chunk

**Anatomical suffixes:** FLAIR, PDT2, PDw, T1w, T2starw, T2w, UNIT1, angio, inplaneT1, inplaneT2

**Parametric maps:** Chimap, M0map, MTRmap, MTVmap, MTsat, MWFmap, PDmap, R1map, R2map, R2starmap, RB1map, S0map, T1map, T1rho, T2map, T2starmap, TB1map

**Functional:** bold, cbv, phase, sbref, events, physio, stim

**Diffusion:** dwi, sbref

**Perfusion:** asl, m0scan, aslcontext

**Field maps:** magnitude1, magnitude2, phasediff, phase1, phase2, fieldmap, magnitude, epi

**File extensions:** .nii, .json, .tsv, .bval, .bvec (with optional .gz compression)
