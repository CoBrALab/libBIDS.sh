# Repository Guidelines

## Project Overview

libBIDS.sh is a single-file Bash library (>=4.3) for parsing BIDS (Brain Imaging Data Structure) datasets into TSV format. It provides filtering, iteration, and JSON metadata processing capabilities for neuroimaging data.

**Key characteristics:**
- 794-line Bash library following functional programming patterns
- AWK-based data processing for TSV filtering and column operations
- Extensible custom entity support via JSON configurations
- Zero-dependency core (jq optional for JSON features)

## Architecture & Data Flow

### Single-File Architecture

The entire library lives in `libBIDS.sh` with a plugin architecture:

```
Directory tree → filename parsing → TSV structure → filtering/iteration
                     ↓                    ↓
              glob patterns        AWK processing
              (32 entities)       (column/row ops)
```

### Core Parsing Flow

1. **Pattern Matching**: Uses Bash extended glob patterns to match 32 standard BIDS entities (sub, ses, task, run, etc.)
2. **Filename Parsing**: Regex-based entity extraction into associative arrays
3. **JSON Sidecar Matching**: Exact filename matching (no inheritance resolution)
4. **Output**: TSV format with entity columns, derivatives, data_type, suffix, extension, path

### Public API (7 functions)

- `libBIDSsh_parse_bids_to_table` - Core BIDS parser, main entry point
- `libBIDSsh_table_filter` - AWK-based TSV filtering (columns, rows, drop-na)
- `libBIDSsh_drop_na_columns` - Remove columns with all NA values
- `libBIDSsh_extension_json_rows_to_column_json_path` - JSON metadata column extraction
- `libBIDSsh_table_column_to_array` - Convert TSV column to Bash array
- `libBIDSsh_table_iterator` - Iterate over TSV rows in callbacks
- `libBIDSsh_json_to_associative_array` - Parse JSON into Bash associative array

### Internal Functions (2)

- `_libBIDSsh_parse_filename` - Regex-based entity extraction from filenames
- `_libBIDSsh_load_custom_entities` - Load custom entity definitions from `custom/` directory

## Key Directories

```
libBIDS.sh/
├── libBIDS.sh                    # Main library (all functionality)
├── README.md                     # Comprehensive documentation + API reference
├── generate_entity_patterns.sh   # Utility: generate glob patterns from schema.json
├── custom/                       # Custom entity definitions
│   └── custom_entities.json.tpl # Template for custom entities
└── bids-examples/               # Test datasets (submodule, 40+ datasets)
    ├── run_tests.sh             # BIDS validation script (bids-validator)
    └── default-config.json      # Validator config (ignore EMPTY_FILE warnings)
```

## Development Commands

### Basic Usage

```bash
# Source the library
source libBIDS.sh

# Parse a BIDS dataset to TSV
libBIDSsh_parse_bids_to_table path/to/bids/dataset

# Direct execution (not sourced)
./libBIDS.sh path/to/bids/dataset
```

### Testing

```bash
# Manual testing with example datasets
./libBIDS.sh bids-examples/ds001

# Validate BIDS compliance (requires bids-validator)
cd bids-examples
./run_tests.sh              # Validate all datasets
./run_tests.sh ds001 ds002  # Validate specific datasets
```

### Development Utilities

```bash
# Generate entity patterns from BIDS schema
./generate_entity_patterns.sh  # Requires schema.json and jq
```

## Code Conventions & Common Patterns

### Bash Requirements

- **Bash >= 4.3** required for:
  - Associative arrays (`declare -A`)
  - Namerefs (`local -n`)
  - `readarray` / `mapfile`
- **Strict mode**: `set -euo pipefail`
- **Version check**: Library validates Bash version on load

### Naming Conventions

- **Public functions**: `libBIDSsh_*` prefix (snake_case)
- **Internal functions**: `_libBIDSsh_*` prefix (private)
- **Local variables**: `local` keyword, lowercase with underscores
- **Associative arrays**: Pass by nameref (`local -n arr="$2"`)

### Error Handling

```bash
# Version check with clear error
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3)); then
  echo "Error: bash >= 4.3 is required" >&2
  exit 1
fi

# Directory validation
if [[ ! -d "$bidspath" ]]; then
  echo "Error: Directory '$bidspath' does not exist" >&2
  return 1
fi
```

### Option Parsing Pattern

```bash
# Case statement for options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c | --columns) columns="$2"; shift 2 ;;
    -r | --row-filter) row_filters+=("$2"); shift 2 ;;
    -d | --drop-na) drop_na_cols="$2"; shift 2 ;;
    -v | --invert) invert_filter="1"; shift ;;
    *) echo "Unknown option: $1" >&2; return 1 ;;
  esac
done
```

### Glob Pattern Usage

```bash
# Enable extended globbing
shopt -s extglob nullglob globstar

# Build BIDS entity patterns
local entities=(
  "*(_sub-+([a-zA-Z0-9]))"
  "*(_ses-+([a-zA-Z0-9]))"
  # ... 30 more entities
)

# Find files
local files=("${bidspath}"/**/${pattern})
```

### AWK Integration

```bash
# TSV processing with AWK
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
  # Direct execution - require argument
  if [[ $# -eq 0 ]]; then
    echo 'error: the first argument must be a path to a bids dataset' >&2
    exit 1
  fi
  libBIDSsh_parse_bids_to_table "${1}"
fi
```

## Important Files

### libBIDS.sh
**Purpose**: Main library containing all functionality

**Key sections**:
- Lines 1-10: Version check and strict mode
- Lines 10-145: Public API - table filtering with AWK
- Lines 415-528: Core BIDS parsing function (`libBIDSsh_parse_bids_to_table`)
- Lines 213-267: Internal filename parser with regex
- Lines 596-747: JSON sidecar processing
- Lines 786-794: Main execution block

### README.md
**Purpose**: Comprehensive documentation with usage examples and API reference

**Sections**:
- Installation and requirements
- Quick start examples
- Complete API reference
- Custom entity extension guide
- Troubleshooting

### generate_entity_patterns.sh
**Purpose**: Generate Bash glob patterns from BIDS schema.json

**Usage**:
```bash
./generate_entity_patterns.sh  # Requires schema.json and jq
```

### custom/custom_entities.json.tpl
**Purpose**: Template for defining custom BIDS entities

**Example**:
```json
{
  "entities": [
    {
      "name": "bp",
      "display_name": "bodypart",
      "pattern": "*(_bp-+([a-zA-Z0-9]))"
    }
  ]
}
```

### bids-examples/run_tests.sh
**Purpose**: Validate BIDS compliance of example datasets

**Features**:
- Accepts optional dataset list
- Supports `.SKIP_VALIDATION` marker files
- Custom validator configs
- Ignores NIfTI headers (except synthetic dataset)

## Runtime/Tooling Preferences

### Required Runtime

- **Bash >= 4.3**: Hard requirement for associative arrays, namerefs
- **AWK**: Standard AWK (typically `awk` or `gawk`)
- **Core utils**: Standard GNU tools (grep, sed, tr, etc.)

### Optional Dependencies

- **jq**: Required for:
  - Custom entity loading
  - JSON sidecar metadata extraction
  - Entity pattern generation
- **bids-validator**: External tool for BIDS compliance validation

### No Package Management

This is a pure Bash library with:
- No npm, pip, cargo, or other package managers
- No build steps
- No compilation
- Source the library directly or execute as script

### Tooling Constraints

- **No formal testing framework**: Manual testing only
- **No CI/CD**: Validation via external bids-validator
- **No linting/formatting tools**: Manual code review
- **No version tracking**: Schema references in comments only

## Testing & QA

### Testing Approach

This project uses **manual testing** without automated test suites:

1. **Direct execution testing**:
   ```bash
   ./libBIDS.sh bids-examples/ds001
   ```

2. **BIDS compliance validation**:
   ```bash
   cd bids-examples
   ./run_tests.sh ds001  # Requires bids-validator
   ```

### Test Fixtures

The `bids-examples/` submodule provides 40+ BIDS datasets:
- **ds001**: Simple fMRI dataset (primary test case)
- **volume_timing**: JSON sidecar testing
- **synthetic**: Complex derivatives testing

### Coverage Expectations

- **No automated test coverage**: Coverage not measured
- **Manual verification**: Test against representative datasets
- **BIDS compliance**: Validated via bids-validator, not libBIDS functionality

### Known Limitations

1. **No unit tests**: Function-level testing not automated
2. **No integration tests**: End-to-end workflows not tested
3. **Silent failures**: Missing jq causes custom entity features to fail silently
4. **JSON inheritance**: Exact filename matching only (no BIDS inheritance resolution)

## Common Workflows

### Adding Custom Entities

1. Create `custom/custom_entities.json` from template
2. Define entity pattern with Bash glob syntax
3. Source library and call `libBIDSsh_parse_bids_to_table`

### Filtering BIDS Datasets

```bash
source libBIDS.sh

# Parse to TSV
table=$(libBIDSsh_parse_bids_to_table path/to/dataset)

# Filter columns
filtered=$(libBIDSsh_table_filter "$table" \
  --columns "sub,task,suffix,path" \
  --row-filter "suffix == \"bold\"")

# Iterate over rows
libBIDSsh_table_iterator "$filtered" callback_function
```

### Processing JSON Metadata

```bash
# Add JSON sidecar data as column
libBIDSsh_extension_json_rows_to_column_json_path "$table" "path" "RepetitionTime"

# Parse JSON file to associative array
declare -A metadata
libBIDSsh_json_to_associative_array "file.json" metadata
```

## Architecture Decisions & Tradeoffs

### Why Single File?

- **Simplicity**: Easy to source, no installation
- **Portability**: Drop into any project
- **Tradeoff**: 794 lines, harder to navigate

### Why AWK for TSV Processing?

- **Performance**: Faster than Bash for text processing
- **Built-in**: No external dependencies
- **Tradeoff**: More complex syntax, harder to debug

### Why No Test Suite?

- **Project maturity**: Early-stage library
- **Developer time**: Manual testing sufficient for current scope
- **Tradeoff**: No regression protection, refactoring risk

### Why Bash 4.3+?

- **Associative arrays**: Essential for entity storage
- **Namerefs**: Clean function interfaces
- **Tradeoff**: Not available on macOS (requires bash via brew)

### Why No JSON Inheritance?

- **Simplicity**: Exact filename matching easier to implement
- **Performance**: No recursive directory traversal
- **Tradeoff**: Not fully BIDS-compliant for complex datasets

## Risks & Limitations

1. **No test suite**: High risk of regressions during changes
2. **Silent jq failures**: Custom entities fail silently if jq missing
3. **Permissive pattern matching**: May match non-BIDS files
4. **No version tracking**: Hard to track schema compatibility
5. **Minimal validation**: Malformed custom entities cause runtime errors
6. **Single file**: Difficult to navigate and maintain as it grows

## Start Here

For AI assistants working with this codebase:

1. **Understand BIDS**: Read [BIDS specification](https://bids-specification.readthedocs.io/)
2. **Read README.md**: Complete usage overview and API reference
3. **Examine libBIDS.sh**: Inline documentation for all functions
4. **Test manually**: Use bids-examples datasets to verify changes
5. **Check custom entities**: Review `custom/custom_entities.json.tpl` for extension pattern
