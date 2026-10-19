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
- Bash library (about 1100 lines), functional/pipeline style
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
          suffix+extension         AWK processing
              glob match           (column/row ops)
```

### Core Parsing Flow

1. **Pattern matching**: a Bash extended-glob pattern `*_<suffix><extension>`
   selects files by schema suffix and extension only. Entity tokens are not
   checked during matching (permissive matching). Also matched: suffix-only
   sidecars (`T1w.json`), and `participants`/`samples`/`phenotype/*` `.tsv`/`.json`
   at the dataset (or derivatives pipeline) root. `find -L` lists the candidates;
   it follows symlinked directories and does not go into `.ds`/`.mefd`/`.ome.zarr`.
2. **Filename parsing**: regex-based entity extraction into associative arrays.
   The extension is the longest schema extension at the end of the filename
   (fallback: all after the first `.`). Tokens with a core column key (`path`,
   `datatype`, `derivatives`, `suffix`, `extension`) are ignored.
3. **JSON sidecar matching**: exact filename matching only (no inheritance
   resolution).
4. **Output**: TSV table with columns `derivatives`, `datatype`, one column per
   BIDS entity, `suffix`, `extension`, `path`.

### Pipeline (typical order)

1. **Parse**: `libBIDSsh_parse_bids_to_table` — BIDS directory → TSV (honors
   `.bidsignore` by default; `--no-bidsignore` / `--no-default-ignores` to opt out)
2. *(optional)* `libBIDSsh_apply_bidsignore` — drop rows excluded by `.bidsignore`
3. *(optional)* `libBIDSsh_extension_json_rows_to_column_json_path` — link JSON sidecars
4. *(optional)* `libBIDSsh_drop_na_columns` — remove all-NA columns
5. **Filter**: `libBIDSsh_table_filter` — keep columns / filter rows / drop NA
6. **Extract**: `libBIDSsh_table_column_to_array` — column → Bash array
7. **Iterate**: `libBIDSsh_table_iterator` — row-by-row with sorting

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
Passing an entity key like `sub` does not match (it is neither a known column name
nor a numeric index). `libBIDSsh_table_filter` then prints an error to stderr and
returns 1. Numeric (1-based) column indices are also accepted.

### Core table structure

Each row is one file. Columns:
- `derivatives` — pipeline name if under a `derivatives/` folder, else `NA`;
  the innermost pipeline for nested `derivatives/a/derivatives/b/...` (`b`)
- `datatype` — BIDS datatype (`anat`, `func`, `dwi`, ...); `NA` at the dataset root
- Both are computed from the path **relative to the dataset root**, so directories
  above the root (e.g. `/data/derivatives/study/`) have no effect.
- BIDS entities — `subject`, `session`, `task`, `acquisition`, `run`, ...; each value
  is the full `<key>-<label>` pair (`sub-01`, `run-1`), not the bare label (`01`)
- `suffix` — file suffix (`bold`, `T1w`, `dwi`, ...); for a core or table file
  (`dataset_description.json`, `participants.*`, `samples.*`, `phenotype/*`) the
  whole stem (e.g. `participants`, `dataset_description`)
- `extension` — file extension **without** the leading dot (`nii.gz`, `json`); the
  BIDS schema (`objects.extensions[].value`) writes it with the dot (`.nii.gz`)
- `path` — full file path
- *(optional)* `json_path` — added by `..._json_rows_to_column_json_path`

Values are written without escapes. A path that contains a tab or a newline breaks
the TSV structure (a tab moves the columns, a newline splits the row).

### Public API (8 functions)

- `libBIDSsh_parse_bids_to_table` — core BIDS parser, main entry point (honors
  `.bidsignore` by default; `--no-bidsignore` / `--no-default-ignores` flags)
- `libBIDSsh_table_filter` — AWK-based TSV filtering (columns, rows, drop-na, invert)
- `libBIDSsh_drop_na_columns` — remove columns whose values are all `NA`
- `libBIDSsh_apply_bidsignore` — drop rows excluded by a dataset's `.bidsignore`
- `libBIDSsh_extension_json_rows_to_column_json_path` — fold JSON sidecar rows into a `json_path` column
- `libBIDSsh_table_column_to_array` — TSV column → Bash array
- `libBIDSsh_table_iterator` — iterate TSV rows into an associative array, with sorting
- `libBIDSsh_json_to_associative_array` — parse a JSON file into a Bash associative array

### Internal Functions (8)

- `_libBIDSsh_normalize_path` — normalize a path spelling (collapse `//`, drop `.` components and trailing `/`) without a subprocess
- `_libBIDSsh_relative_path` — path relative to a dataset root, for equivalent spellings of the root
- `_libBIDSsh_parse_filename` — regex-based entity extraction from a filename (optional 3rd arg: dataset root)
- `_libBIDSsh_load_custom_entities` — load custom entity definitions from `custom/*.json`
- `_libBIDSsh_compile_bidsignore_line` — compile one gitignore-style pattern to an anchored ERE
- `_libBIDSsh_compile_bidsignore` — compile default ignores + root `.bidsignore` into match arrays
- `_libBIDSsh_path_is_ignored` — test a dataset-relative path against the compiled patterns (last-match-wins)
- `_libBIDSsh_iterator_clear` — remove the cached `libBIDSsh_table_iterator` state for one row array

## Key Directories

```
libBIDS.sh/
├── libBIDS.sh                    # Main library (all functionality)
├── test_libBIDS.sh               # Unit test suite (self-contained runner)
├── README.md                     # User documentation + API reference
├── schema.json                   # BIDS schema (NOT tracked in git; download it)
├── generate_entity_patterns.sh   # Utility: generate glob patterns from schema.json
├── custom/                       # Custom entity definitions
│   └── custom_entities.json.tpl  # Template for custom entities
└── bids-examples/                # Test datasets (git submodule, pinned commit)
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
# Get the bids-examples submodule (once per clone)
git submodule update --init

# Run the unit test suite (sources libBIDS.sh, self-contained runner).
# It works from any CWD and stops with an error if bids-examples/ is missing.
./test_libBIDS.sh

# Also run the suite with bash 4.3 (the documented minimum) if available
/path/to/bash-4.3 ./test_libBIDS.sh

# Manual smoke test against an example dataset
./libBIDS.sh bids-examples/ds001

# Validate BIDS compliance (requires bids-validator)
cd bids-examples
./run_tests.sh                # Validate all datasets
./run_tests.sh ds001 ds002    # Validate specific datasets
```

### Development Utilities

```bash
# Generate the schema-derived parser blocks (requires schema.json + jq).
# schema.json is not tracked in git. The script reads ./schema.json from the
# CWD, so run it from the repository root after you download the schema:
curl -LO https://bids-specification.readthedocs.io/en/latest/schema.json
./generate_entity_patterns.sh
```

## Code Conventions & Common Patterns

### Bash Requirements

- **Bash >= 4.3**, required for:
  - associative arrays (`declare -A`)
  - namerefs (`local -n` / `declare -n`)
  - `readarray` / `mapfile`
- **Strict mode**: `set -euo pipefail`
- **Empty arrays under `set -u`**: before Bash 4.4, `"${arr[@]}"` on an empty
  array is an "unbound variable" error. Expand an array that can be empty as
  `${arr[@]+"${arr[@]}"}` (or guard it with a `${#arr[@]}` check).
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

`--row-filter` takes `column:pattern`. The value is split at the **first** `:` only
(the pattern can contain `:`), and the pattern is matched against the column as an
unanchored **AWK extended regex** (`~`, substring match). It is NOT an AWK
expression. Use `^...$` for an exact match (`sub-01` also matches `sub-010`).
Multiple `-r` filters combine with AND. `--invert` keeps the exact complement:
it removes the rows that match all filters and keeps all other rows.

```bash
# keep rows where task column matches "rest" AND subject is exactly "sub-01"
-r "task:rest" -r "subject:^sub-01$"
```

### Glob Pattern Usage

```bash
# Enable extended globbing (save the caller's option first, restore after)
saved_shopts=$(shopt -p extglob) || true
shopt -s extglob

# Match by schema suffix and extension only (both lists are generated from
# schema.json by generate_entity_patterns.sh)
local pattern="*${suffixes}${extensions}"

# Find files: 'find -L' follows symlinked directories (globstar does not) and
# stops at link loops; dot names are pruned; 'sort -z' keeps the glob order.
# Each basename is then tested against the extglob pattern.
while IFS= read -r -d '' found; do
  [[ ${found##*/} == ${pattern} ]] && files+=("${found}")
done < <(find -L "${bidspath}" -mindepth 1 -name '.*' -prune -o -print0 | sort -z)
```

### AWK Integration

Write POSIX awk only (no arrays of arrays, no `length(array)`, no reliance on
`for (k in arr)` order), so that the code runs on gawk, mawk and BSD awk. Pass
regex patterns through the environment and read them with `ENVIRON`, because
`awk -v` processes backslash escapes (`\.` becomes `.`):

```bash
LIBBIDSSH_ROW_FILTERS="${row_filters_str}" \
  awk 'BEGIN { FS="\t"; OFS="\t"; filters = ENVIRON["LIBBIDSSH_ROW_FILTERS"] } ...'
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
  # _libBIDSsh_usage is defined here; it prints the usage text (heredoc) to stdout.

  if [[ $# -eq 0 ]]; then
    echo 'error: the first argument must be a path to a bids dataset' >&2
    _libBIDSsh_usage >&2
    exit 1
  fi
  # Look for -h/--help among the options (stop at "--").
  for _libBIDSsh_arg in "$@"; do
    case "${_libBIDSsh_arg}" in
      --) break ;;
      -h | --help)
        _libBIDSsh_usage
        exit 0
        ;;
    esac
  done
  unset _libBIDSsh_arg
  libBIDSsh_parse_bids_to_table "$@"
fi
```

## Important Files

### libBIDS.sh

**Purpose**: Main library containing all functionality (about 1100 lines).

**Approximate section map** (verify with `grep -n '^libBIDSsh_\|^_libBIDSsh_' libBIDS.sh`):
- Version check + strict mode — top of file
- `libBIDSsh_table_filter` — TSV filtering with AWK
- `libBIDSsh_drop_na_columns` — drop all-NA columns
- `_libBIDSsh_normalize_path`, `_libBIDSsh_relative_path` — path helpers
- `_libBIDSsh_parse_filename` — regex filename parser
- `libBIDSsh_extension_json_rows_to_column_json_path` — JSON sidecar folding
- `_libBIDSsh_load_custom_entities` — custom entity loader
- `_libBIDSsh_compile_bidsignore_line`, `_libBIDSsh_compile_bidsignore`,
  `_libBIDSsh_path_is_ignored` — `.bidsignore` pattern compile and match
- `libBIDSsh_apply_bidsignore` — drop `.bidsignore`-excluded rows from a table
- `libBIDSsh_parse_bids_to_table` — core BIDS parser (entity/suffix/extension globs)
- `libBIDSsh_table_column_to_array` — column → array
- `libBIDSsh_table_iterator` — row iteration with sorting
- `libBIDSsh_json_to_associative_array` — JSON → associative array
- Main execution block — bottom of file

### README.md

Comprehensive user documentation: installation, quick start, full API reference,
custom-entity extension guide, troubleshooting.

### generate_entity_patterns.sh

Generates the schema-derived blocks of the parser (entity key and name lists for
the columns, the suffix and extension glob alternations, the datatype regex)
from the BIDS `schema.json`. Requires `schema.json` and `jq`. `schema.json` is the authoritative BIDS spec source, but it is **not
tracked** in git (`.gitignore` lists it). Download it from
<https://bids-specification.readthedocs.io/en/latest/schema.json> into the
repository root. The script reads `./schema.json` relative to the CWD, so run it
from the repository root.

### custom/custom_entities.json.tpl

Template for defining custom BIDS entities. Copy to `custom/custom_entities.json`
to activate (the parser loads every `custom/*.json`). The `custom/` directory is
found next to the real `libBIDS.sh` file, also when it is sourced through a symlink,
and not in the CWD or the dataset.
Only `key` and `name` have an effect. `pattern` is accepted but is not used for
matching (files are selected by suffix and extension only).

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

`bids-examples/` is a git submodule pinned to one upstream commit (about 110
datasets). `run_tests.sh` belongs to the upstream bids-examples repository, not to
this project.

Validates BIDS compliance of example datasets. Features:
- accepts an optional dataset list (defaults to all dirs except `node_modules`)
- skips datasets containing a `.SKIP_VALIDATION` marker file
- uses `default-config.json` unless a dataset provides `.bids-validator-config.json`
- passes `--ignoreNiftiHeaders` for all datasets except `synthetic/`

## Runtime/Tooling Preferences

### Required Runtime

- **Bash >= 4.3** (hard requirement: associative arrays, namerefs)
- **AWK** (any POSIX awk: gawk, mawk, BSD awk)
- **Core utils**: standard GNU tools (`grep`, `sed`, `tr`, `paste`, `sort`, ...);
  the parser uses `find -L ... -print0 | sort -z` for file discovery

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
- `run_test` runs each test in a subshell with `set -e`, and `assert_*` record a
  failure flag, so any failed assertion or command fails the test. Use
  `skip_test "<reason>"` to skip a test, use `${bids_examples}/<dataset>` for
  example datasets, and create fixtures under `${test_tmpdir}` (removed on exit).
- CI: GitHub Actions (`.github/workflows/tests.yml`) runs on each push to
  `master` and each pull request (no branch filter, so stacked PRs also run).
  Jobs: unit tests and a parse of every bids-examples dataset (matrix of bash
  version x awk implementation), and `shellcheck -S warning`. When a change makes
  a new bash or awk version pass, add it to the matrix.
- `bids-examples/` is a git submodule pinned to one upstream commit. To update it,
  check out a new commit in the submodule and commit the new gitlink; expect test
  and table changes from the new datasets.
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
`-r` reverses. Rows are always sorted (`sort --version-sort`); with no sort columns
they are sorted by all columns, left to right. Use it in a `while` loop:

```bash
declare -A row
while libBIDSsh_table_iterator "$filtered" row "subject" "run"; do
  echo "${row[path]}"   # access fields by column name
done
```

The first call sorts the table once. The sorted rows and the cursor are kept in the
module-level `_LIBBIDSSH_ITER_*` associative arrays, keyed by the row array name
(the row array holds only column keys). A different table or different sort args
start a new iteration; the state is removed after the last row. After a `break`,
the same array + table + sort args continue where they stopped; `row=()` or a call
with an empty table (`libBIDSsh_table_iterator "" row || true`) starts again, and so
does a new array (`local -A row`). Do not reset with `unset row` alone (the next call
fails); declare the array again after `unset`. Nested
loops must use different array names (the state is keyed by the name). Do not
change the table string inside the loop body (a changed table starts again from
row 0). After a `break`, the state (a copy of the table and its sorted rows) stays
in memory until the next call or a reset. Row array names that start with `_lbit_`
are reserved (all locals of the iterator use this prefix, so names like `line` or
`i` are safe).

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
2. Define each entity's `key` (short filename token, required) and `name` (the
   column header, required). The optional `pattern` field is not used for
   matching: files are selected by suffix and extension only. A `key` or `name`
   that is the same as a standard entity, a fixed column or an earlier custom
   entity is skipped with a warning to stderr.
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
   stderr) if `jq` is missing. `libBIDSsh_json_to_associative_array` also returns 1
   (and leaves its array empty) if `jq` is missing, the file is not valid JSON,
   the top level is not an object, or the target is not a `declare -A` array. Its `array:a,b` value format is lossy: items
   are joined with `,` without escapes, and `null` items are empty.
2. **Permissive pattern matching** — may match files that are not valid BIDS.
3. **JSON sidecars** — `..._json_rows_to_column_json_path` matches only a JSON file
   with the exact same name (different extension); no inheritance hierarchy resolution.
4. **Malformed custom entities** — a `custom/*.json` file that is not valid JSON or
   has no `entities` array makes the parser write the file name to stderr and
   return 1.
5. **`.bidsignore`** — only the **root-level** `.bidsignore` is read (no inheritance /
   nested files, matching `bids-validator`). Negation (`!`) does not specially block
   re-including a file under an already-excluded parent directory — each file's full
   relative path is tested independently. Escaped trailing whitespace (`\ `) is the
   one gitignore corner not fully honored. A directory-only pattern (trailing `/`)
   also matches a directory-valued row (`.ds`, `.mefd`, `.ome.zarr`). Because the parser only globs valid-BIDS
   suffix+extension files, `.bidsignore` patterns targeting non-BIDS files are no-ops.
   Built-in default ignores follow `bids-validator` (`/sourcedata/`, `/code/`,
   `/stimuli/`, `/log/`, `/doc/`, `.**`, `!/.bidsignore`), root-anchored, except
   that `/derivatives/` is not ignored. `docs/` and `logs/` (schema opaque dirs)
   are not ignored by default.

## Start Here (for AI assistants)

1. **Understand BIDS** — see the [BIDS specification](https://bids-specification.readthedocs.io/).
2. **Read README.md** — usage overview and full API reference.
3. **Read libBIDS.sh** — inline docstrings document every function and its args.
4. **Mind the column-naming convention** — entity names (e.g. `subject`), not entity keys (e.g. `sub`).
5. **Test manually** — run against `bids-examples/` datasets to verify changes.
6. **Check custom entities** — review `custom/custom_entities.json.tpl`.
</content>
</invoke>
