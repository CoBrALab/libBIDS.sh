# Repository Guidelines

> This file is the single source of guidance for AI assistants (Claude Code, etc.)
> working in this repository. `CLAUDE.md` is a symlink to this file.

## Project Overview

libBIDS.sh is a single-file Bash library (>= 4.3) for parsing BIDS (Brain Imaging
Data Structure) datasets into a **TSV** (tab-separated) table. It provides
filtering, column extraction, row iteration, and JSON sidecar/metadata processing
for neuroimaging data. The design follows a pipeline pattern: functions accept a
TSV string and return a processed TSV string.

**Key characteristics:**
- ~810-line Bash library, functional/pipeline style
- AWK-based data processing for TSV filtering and column operations
- Extensible custom entity support via JSON configurations
- Zero-dependency core (`jq` optional, for JSON features and custom entities)

## Architecture & Data Flow

### Single-File Architecture

The entire library lives in `libBIDS.sh`. There is no build step — source the file
or run it directly.

```
Directory tree → filename parsing → TSV table → filtering / extraction / iteration
                     ↓                   ↓
              glob patterns         AWK processing
              (35 entities)        (column/row ops)
```

### Core Parsing Flow

1. **Pattern matching**: Bash extended-glob patterns match 35 standard BIDS
   entities (`sub`, `ses`, `task`, `run`, ...) plus suffixes and extensions.
2. **Filename parsing**: regex-based entity extraction into associative arrays.
3. **JSON sidecar matching**: exact filename matching only (no inheritance
   resolution).
4. **Output**: TSV table with columns `derivatives`, `datatype`, one column per
   BIDS entity, `suffix`, `extension`, `path`.

### Pipeline (typical order)

1. **Parse**: `libBIDSsh_parse_bids_to_table` — BIDS directory → TSV
2. *(optional)* `libBIDSsh_extension_json_rows_to_column_json_path` — link JSON sidecars
3. *(optional)* `libBIDSsh_drop_na_columns` — remove all-NA columns
4. **Filter**: `libBIDSsh_table_filter` — keep columns / filter rows / drop NA
5. **Extract**: `libBIDSsh_table_column_to_array` — column → Bash array
6. **Iterate**: `libBIDSsh_table_iterator` — row-by-row with sorting

## Column Naming Convention (CRITICAL)

BIDS nomenclature (per `schema.json`, `objects.entities`) distinguishes three things
per entity — get these right:

| concept              | schema source     | example   | used as            |
|----------------------|-------------------|-----------|--------------------|
| entity **key**       | `.name`           | `sub`     | filename token     |
| entity **name**      | object key        | `subject` | **table column**   |
| entity display name  | `.display_name`   | `Subject` | not used here      |

Table columns use the entity **name** (the long form), not the entity **key** (the
short token used in filenames):

| entity key | column name (entity name) |
|------------|---------------------------|
| `sub`      | `subject`                 |
| `ses`      | `session`                 |
| `acq`      | `acquisition`             |
| `rec`      | `reconstruction`          |
| `dir`      | `direction`               |
| `task`     | `task` (same)             |
| `run`      | `run` (same)              |

When passing column names to `--columns`, `--row-filter`, `--drop-na`, sort keys,
or `libBIDSsh_table_column_to_array`, use the entity **name** (e.g. `subject`).
Passing an entity key like `sub` will silently fail to match (it is neither a known
column name nor a numeric index). Numeric column indices are also accepted.

### Core table structure

Each row is one file. Columns:
- `derivatives` — pipeline name if under a `derivatives/` folder, else `NA`
- `datatype` — BIDS datatype (`anat`, `func`, `dwi`, ...)
- BIDS entities — `subject`, `session`, `task`, `acquisition`, `run`, ...
- `suffix` — file suffix (`bold`, `T1w`, `dwi`, ...)
- `extension` — file extension
- `path` — full file path
- *(optional)* `json_path` — added by `..._json_rows_to_column_json_path`

### Public API (7 functions)

- `libBIDSsh_parse_bids_to_table` — core BIDS parser, main entry point
- `libBIDSsh_table_filter` — AWK-based TSV filtering (columns, rows, drop-na, invert)
- `libBIDSsh_drop_na_columns` — remove columns whose values are all `NA`
- `libBIDSsh_extension_json_rows_to_column_json_path` — fold JSON sidecar rows into a `json_path` column
- `libBIDSsh_table_column_to_array` — TSV column → Bash array
- `libBIDSsh_table_iterator` — iterate TSV rows into an associative array, with sorting
- `libBIDSsh_json_to_associative_array` — parse a JSON file into a Bash associative array

### Internal Functions (2)

- `_libBIDSsh_parse_filename` — regex-based entity extraction from a filename
- `_libBIDSsh_load_custom_entities` — load custom entity definitions from `custom/*.json`

## Key Directories

```
libBIDS.sh/
├── libBIDS.sh                    # Main library (all functionality)
├── test_libBIDS.sh               # Unit test suite (self-contained runner)
├── README.md                     # User documentation + API reference
├── schema.json                   # BIDS specification (authoritative source)
├── generate_entity_patterns.sh   # Utility: generate glob patterns from schema.json
├── custom/                       # Custom entity definitions
│   └── custom_entities.json.tpl  # Template for custom entities
└── bids-examples/                # Test datasets (submodule, 40+ datasets)
    ├── run_tests.sh              # BIDS validation script (bids-validator)
    └── default-config.json       # Validator config
```

## Development Commands

### Basic Usage

```bash
# Source the library
source libBIDS.sh

# Parse a BIDS dataset to TSV
libBIDSsh_parse_bids_to_table path/to/bids/dataset

# Direct execution (dumps dataset as TSV to stdout)
./libBIDS.sh path/to/bids/dataset
```

### Testing

```bash
# Run the unit test suite (sources libBIDS.sh, self-contained runner)
./test_libBIDS.sh

# Manual smoke test against an example dataset
./libBIDS.sh bids-examples/ds001

# Validate BIDS compliance (requires bids-validator)
cd bids-examples
./run_tests.sh                # Validate all datasets
./run_tests.sh ds001 ds002    # Validate specific datasets
```

### Development Utilities

```bash
# Generate entity glob patterns from the BIDS schema (requires schema.json + jq)
./generate_entity_patterns.sh
```

## Code Conventions & Common Patterns

### Bash Requirements

- **Bash >= 4.3**, required for:
  - associative arrays (`declare -A`)
  - namerefs (`local -n` / `declare -n`)
  - `readarray` / `mapfile`
- **Strict mode**: `set -euo pipefail`
- **Version check**: the library validates the Bash version on load and exits otherwise.
- macOS default Bash (3.2) is too old; install a newer Bash (e.g. via Homebrew).

### Naming Conventions

- **Public functions**: `libBIDSsh_*` prefix (snake_case)
- **Internal functions**: `_libBIDSsh_*` prefix (private)
- **Local variables**: `local`, lowercase with underscores
- **Associative arrays**: passed by nameref (`local -n arr="$2"`)

### Error Handling

```bash
# Version check with clear error
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "Error: bash >= 4.3 is required" >&2
  exit 1
fi

# Directory validation
if [[ ! -d "$bidspath" ]]; then
  echo "Error: Directory '$bidspath' does not exist" >&2
  return 1
fi
```

All data is passed as TSV strings, not files. `NA` represents a missing BIDS entity.

### Option Parsing Pattern

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c | --columns)    columns="$2";        shift 2 ;;
    -r | --row-filter) row_filters+=("$2"); shift 2 ;;
    -d | --drop-na)    drop_na_cols="$2";   shift 2 ;;
    -v | --invert)     invert_filter="1";   shift   ;;
    *) echo "Unknown option: $1" >&2; return 1 ;;
  esac
done
```

### Row-Filter Syntax (important)

`--row-filter` takes `column:pattern`. Internally the `:` is split to a tab and
the pattern is matched against the column as an **AWK regex** (`~`). It is NOT an
AWK expression. Multiple `-r` filters combine with AND. `--invert` removes
matching rows instead of keeping them.

```bash
# keep rows where task column matches "rest" AND subject matches "sub-01"
-r "task:rest" -r "subject:sub-01"
```

### Glob Pattern Usage

```bash
# Enable extended globbing
shopt -s extglob nullglob globstar

# Build BIDS entity patterns (35 standard entities, defined inline in the parser)
local entities=(
  "*(_sub-+([a-zA-Z0-9]))"
  "*(_tpl-+([a-zA-Z0-9]))"
  # ... 33 more entities
)

# Find files
local files=("${bidspath}"/**/${pattern})
```

### AWK Integration

```bash
awk -v columns="${columns}" \
    -v row_filters_str="${row_filters_str}" \
    'BEGIN { FS="\t"; OFS="\t" } ...'
```

### JSON Processing

```bash
# Parse JSON with jq (type-prefixed values)
jq -r 'to_entries[] |
  "\(.key)=\(
    if .value|type == "array" then "array:" + (.value|join(","))
    elif .value|type == "object" then "object:" + (.value|tostring)
    else (.value|type) + ":" + (.value|tostring)
    end
  )"' "$json_file"
```

### Entry Point Pattern

```bash
# Detect sourced vs direct execution
if ! (return 0 2>/dev/null); then
  if [[ $# -eq 0 ]]; then
    echo 'error: the first argument must be a path to a bids dataset' >&2
    exit 1
  fi
  libBIDSsh_parse_bids_to_table "${1}"
fi
```

## Important Files

### libBIDS.sh

**Purpose**: Main library containing all functionality (~810 lines).

**Approximate section map** (verify with `grep -n '^libBIDSsh_\|^_libBIDSsh_' libBIDS.sh`):
- Version check + strict mode — top of file
- `libBIDSsh_table_filter` — TSV filtering with AWK
- `libBIDSsh_drop_na_columns` — drop all-NA columns
- `_libBIDSsh_parse_filename` — regex filename parser
- `libBIDSsh_extension_json_rows_to_column_json_path` — JSON sidecar folding
- `_libBIDSsh_load_custom_entities` — custom entity loader
- `libBIDSsh_parse_bids_to_table` — core BIDS parser (entity/suffix/extension globs)
- `libBIDSsh_table_column_to_array` — column → array
- `libBIDSsh_table_iterator` — row iteration with sorting
- `libBIDSsh_json_to_associative_array` — JSON → associative array
- Main execution block — bottom of file

### README.md

Comprehensive user documentation: installation, quick start, full API reference,
custom-entity extension guide, troubleshooting.

### generate_entity_patterns.sh

Generates Bash glob patterns from the BIDS `schema.json`. Requires `schema.json`
and `jq`. `schema.json` is the authoritative BIDS spec source.

### custom/custom_entities.json.tpl

Template for defining custom BIDS entities. Copy to `custom/custom_entities.json`
to activate (the parser loads every `custom/*.json`).

```json
{
  "entities": [
    {
      "key": "bp",
      "name": "bodypart",
      "pattern": "*(_bp-+([a-zA-Z0-9]))"
    }
  ]
}
```

### bids-examples/run_tests.sh

Validates BIDS compliance of example datasets. Features:
- accepts an optional dataset list (defaults to all dirs except `node_modules`)
- skips datasets containing a `.SKIP_VALIDATION` marker file
- uses `default-config.json` unless a dataset provides `.bids-validator-config.json`
- passes `--ignoreNiftiHeaders` for all datasets except `synthetic/`

## Runtime/Tooling Preferences

### Required Runtime

- **Bash >= 4.3** (hard requirement: associative arrays, namerefs)
- **AWK** (`awk` / `gawk`)
- **Core utils**: standard GNU tools (`grep`, `sed`, `tr`, `paste`, `sort`, ...)

### Optional Dependencies

- **jq** — required for:
  - custom entity loading
  - JSON sidecar metadata extraction (`libBIDSsh_json_to_associative_array`)
  - entity pattern generation
- **bids-validator** — external tool for BIDS compliance validation (testing only)

### No Package Management / Build

Pure Bash library: no npm/pip/cargo, no build step, no compilation. Source it or
run it directly.

### Tooling Constraints

- Unit tests live in `test_libBIDS.sh` (run with `./test_libBIDS.sh`); BIDS
  compliance is validated separately via the external bids-validator.
- No CI/CD pipeline.
- `shellcheck` directives are used inline (`# shellcheck disable=...`); code follows
  the Google Shell Style Guide.

## Common Workflows

### Filtering a BIDS dataset

```bash
source libBIDS.sh

# Parse to TSV
table=$(libBIDSsh_parse_bids_to_table path/to/dataset)

# Drop empty columns
table=$(libBIDSsh_drop_na_columns "$table")

# Keep selected columns and filter rows (use FULL column names, colon syntax)
filtered=$(libBIDSsh_table_filter "$table" \
  --columns "subject,task,suffix,path" \
  --row-filter "suffix:bold" \
  --row-filter "task:rest")
```

### Extracting a column

```bash
declare -a subjects
# args: table, column, array_ref, [unique=true], [exclude_NA=true]
libBIDSsh_table_column_to_array "$filtered" "subject" subjects true true
```

### Iterating over rows

`libBIDSsh_table_iterator` populates an associative array (by nameref) one row per
call and returns 0 while rows remain, 1 when done. Trailing args are sort columns;
`-r` reverses. Use it in a `while` loop:

```bash
declare -A row
while libBIDSsh_table_iterator "$filtered" row "subject" "run"; do
  echo "${row[path]}"   # access fields by column name
done
```

### Processing JSON metadata

```bash
# Fold JSON sidecar rows into a json_path column
table=$(libBIDSsh_extension_json_rows_to_column_json_path "$table")

# Parse a JSON file into an associative array (values are type-prefixed)
declare -A metadata
libBIDSsh_json_to_associative_array "file.json" metadata
```

### Adding custom entities

1. Copy `custom/custom_entities.json.tpl` to `custom/custom_entities.json`.
2. Define each entity's `key` (short filename token), `name` (the column header),
   and `pattern` (Bash extended-glob).
3. Source the library and call `libBIDSsh_parse_bids_to_table`; custom entities are
   appended after the standard ones.

## Architecture Decisions & Tradeoffs

- **Single file** — simple to source/drop-in and portable; tradeoff: harder to
  navigate as it grows.
- **AWK for TSV processing** — fast, built-in, no deps; tradeoff: harder to read/debug.
- **Bash 4.3+** — needed for associative arrays and namerefs; tradeoff: excludes
  stock macOS Bash.
- **Permissive matching** — intentionally does NOT enforce strict BIDS compliance;
  may match non-BIDS-compliant files. Flexibility over validation.
- **No JSON inheritance** — exact filename sidecar matching only; tradeoff: not
  fully BIDS-compliant for datasets relying on the inheritance principle.

## Risks & Limitations

1. **Silent `jq` failures** — custom-entity / JSON features fail (with an error to
   stderr) if `jq` is missing.
2. **Permissive pattern matching** — may match files that are not valid BIDS.
3. **JSON sidecars** — `..._json_rows_to_column_json_path` matches only a JSON file
   with the exact same name (different extension); no inheritance hierarchy resolution.
4. **Malformed custom entities** — can cause runtime errors.

## Start Here (for AI assistants)

1. **Understand BIDS** — see the [BIDS specification](https://bids-specification.readthedocs.io/).
2. **Read README.md** — usage overview and full API reference.
3. **Read libBIDS.sh** — inline docstrings document every function and its args.
4. **Mind the column-naming convention** — entity names (e.g. `subject`), not entity keys (e.g. `sub`).
5. **Test manually** — run against `bids-examples/` datasets to verify changes.
6. **Check custom entities** — review `custom/custom_entities.json.tpl`.
</content>
</invoke>
