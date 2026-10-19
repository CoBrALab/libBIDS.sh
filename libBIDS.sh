#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "Error: bash >= 4.3 is required for this script" >&2
  exit 1
fi

set -euo pipefail

libBIDSsh_table_filter() {
  # Filter TSV-structured BIDS data, returning specified columns and optionally filtering rows
  # Usage: libBIDSsh_table_filter "${table_data}" [OPTIONS]
  # Options:
  #   -c, --columns <list>      Comma-separated list of column indices or names to keep,
  #                             printed in the given order
  #   -r, --row-filter <col:pattern> Keep rows where column matches pattern. The pattern is
  #                             an unanchored AWK extended regex (substring match); use
  #                             ^...$ for an exact match. Only the first ':' separates the
  #                             column from the pattern. Multiple -r filters combine with AND.
  #   -v, --invert              Invert row filter logic (remove the rows that match all
  #                             -r filters, keep all other rows)
  #   -d, --drop-na <list>      Comma-separated list of columns to check for NA values
  # Columns are given by name (the first header field with that name) or by 1-based index.
  # An unknown column name or an index out of range is an error (return 1, nothing printed).
  # Returns: Filtered TSV data through stdout
  # Example:
  #   filtered=$(libBIDSsh_table_filter "$data" -c "subject,session" -r "task:^task-rest$" -d "run")
  local table_data="$1"
  shift

  local columns=""
  local row_filters_str=""
  local drop_na_cols=""
  local invert_filter=""

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c | --columns)
        if [[ $# -lt 2 ]]; then
          echo "Error: $1 requires an argument" >&2
          return 1
        fi
        columns="$2"
        shift 2
        ;;
      -r | --row-filter)
        if [[ $# -lt 2 ]]; then
          echo "Error: $1 requires an argument" >&2
          return 1
        fi
        if [[ "$2" != *:* || "$2" == *$'\n'* ]]; then
          echo "Error: $1 requires a single-line col:pattern argument, got '$2'" >&2
          return 1
        fi
        # Split at the first ':' only, so that the pattern can contain ':'
        row_filters_str+="${2%%:*}"$'\t'"${2#*:}"$'\n'
        shift 2
        ;;
      -d | --drop-na)
        if [[ $# -lt 2 ]]; then
          echo "Error: $1 requires an argument" >&2
          return 1
        fi
        drop_na_cols="$2"
        shift 2
        ;;
      -v | --invert)
        invert_filter="1"
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  # Values go through the environment and not through 'awk -v', because awk
  # processes backslash escapes in -v values (a pattern '\.' would become '.').
  # The program uses POSIX awk only, so that it runs on gawk, mawk and BSD awk.
  LIBBIDSSH_COLUMNS="${columns}" \
    LIBBIDSSH_ROW_FILTERS="${row_filters_str}" \
    LIBBIDSSH_DROP_NA_COLS="${drop_na_cols}" \
    LIBBIDSSH_INVERT="${invert_filter}" \
    awk '
        function resolve_column(name, kind) {
            # Return the field index of a column name or index, or exit 1
            if (name in colnames) return colnames[name];
            if (name ~ /^[0-9]+$/ && name + 0 >= 1 && name + 0 <= NF) return name + 0;
            # Write to stderr through a pipe: "gawk --posix" opens "/dev/stderr"
            # as a file, which truncates a log file that stderr is redirected to.
            print "Error: " kind " \"" name "\" not found in header (use a header name or an index from 1 to " NF ")" | "cat 1>&2";
            close("cat 1>&2");
            exit 1;
        }
        BEGIN {
            FS="\t"; OFS="\t";
            columns = ENVIRON["LIBBIDSSH_COLUMNS"];
            drop_na_cols = ENVIRON["LIBBIDSSH_DROP_NA_COLS"];
            invert_filter = ENVIRON["LIBBIDSSH_INVERT"];
            col_count = (columns != "") ? split(columns, cols, ",") : 0;
            na_count = (drop_na_cols != "") ? split(drop_na_cols, na_cols, ",") : 0;

            # Parse row filters: one "col<TAB>pattern" per line
            filter_count = 0;
            line_count = split(ENVIRON["LIBBIDSSH_ROW_FILTERS"], filter_lines, "\n");
            for (i = 1; i <= line_count; i++) {
                if (filter_lines[i] == "") continue;
                tab = index(filter_lines[i], "\t");
                filter_count++;
                filter_name[filter_count] = substr(filter_lines[i], 1, tab - 1);
                filter_pat[filter_count] = substr(filter_lines[i], tab + 1);
            }
        }
        NR == 1 {
            # Process header; with duplicate names the first one wins
            for (i = 1; i <= NF; i++) {
                if (!($i in colnames)) colnames[$i] = i;
            }

            # Resolve all columns before anything is printed
            for (i = 1; i <= col_count; i++) outcols[i] = resolve_column(cols[i], "Column");
            for (i = 1; i <= filter_count; i++) filter_col[i] = resolve_column(filter_name[i], "Row filter column");
            for (i = 1; i <= na_count; i++) na_col[i] = resolve_column(na_cols[i], "Drop NA column");
        }
        NR > 1 {
            # Row filters combine with AND; invert keeps the exact complement
            if (filter_count > 0) {
                matched = 1;
                for (i = 1; i <= filter_count; i++) {
                    if ($filter_col[i] !~ filter_pat[i]) {
                        matched = 0;
                        break;
                    }
                }
                if (invert_filter == "1" ? matched : !matched) next;
            }

            # Check for NA values in specified columns
            for (i = 1; i <= na_count; i++) {
                if ($na_col[i] == "NA") next;
            }
        }
        {
            # Print row (selected columns or all)
            if (col_count > 0) {
                for (i = 1; i <= col_count; i++) {
                    printf "%s%s", $outcols[i], (i < col_count ? OFS : ORS);
                }
            } else {
                print;
            }
        }' <<<"${table_data}"
}

libBIDSsh_drop_na_columns() {
  # Remove columns from table data that contain only NA values
  # Usage: libBIDSsh_drop_na_columns "${table_data}"
  # Returns: Table data with NA-only columns removed through stdout
  # The header gives the number of columns. Empty lines are ignored. A field
  # that a short row does not have counts as NA and is output as empty.
  # A header-only table (no data rows) is returned unchanged.
  # Example:
  #   cleaned=$(libBIDSsh_drop_na_columns "$data")
  local table_data="$1"
  awk -F'\t' '
    BEGIN {OFS="\t"; nrows = 0}
    NR == 1 {
        # Save header and initialize column tracking
        header = $0
        hnf = NF
        for (i = 1; i <= hnf; i++) {
            col_all_na[i] = 1  # Assume all columns are all NA initially
            header_fields[i] = $i  # Store header names
        }
        next
    }
    NF == 0 { next }  # Ignore empty lines (for example a trailing newline)
    {
        for (i = 1; i <= hnf && i <= NF; i++) {
            if ($i != "NA") {
                col_all_na[i] = 0  # Mark column as not all NA
            }
        }
        # Store all rows for later printing
        rows[++nrows] = $0
    }
    END {
        # A table without data rows has no NA-only columns to remove
        if (nrows == 0) {
            if (NR > 0) {
                print header
            }
            exit
        }

        # Print header (only keeping non-NA columns)
        first_field = 1
        for (i = 1; i <= hnf; i++) {
            if (!col_all_na[i]) {
                if (!first_field) {
                    printf "%s", OFS
                }
                printf "%s", header_fields[i]
                first_field = 0
            }
        }
        printf "\n"

        # Print each row (only keeping non-NA columns)
        for (j = 1; j <= nrows; j++) {
            n = split(rows[j], row_fields, /\t/)
            first_field = 1
            for (i = 1; i <= hnf; i++) {
                if (!col_all_na[i]) {
                    if (!first_field) {
                        printf "%s", OFS
                    }
                    printf "%s", (i <= n ? row_fields[i] : "")
                    first_field = 0
                }
            }
            printf "\n"
        }
    }' <<<"${table_data}"
}

# shellcheck disable=SC2154,SC2034
_libBIDSsh_parse_filename() {
  # Internal function to parse BIDS filenames into components
  # Usage: _libBIDSsh_parse_filename "${path}" array_name
  # Populates associative array with BIDS components (entities, suffix, extension, etc.)
  # Example:
  #   declare -A file_info
  #   _libBIDSsh_parse_filename "sub-01_task-rest_bold.nii.gz" file_info
  local path="$1"
  local -n arr="$2" # nameref to the associative array

  # Extract the filename without path
  local filename
  filename=$(basename "${path}")

  # Initialize the arrays
  arr=()
  local -a key_order=() # To maintain the order of keys

  # Store the full path and filename
  arr[path]=$(tr -s / <<<"${path}")

  arr[extension]="${filename#*.}"

  # Datatype is the BIDS datatype directory directly containing the file (the
  # final component of the file's directory). Anchor to a whole path component
  # so an unrelated substring (e.g. "func" in "study_func/") cannot match.
  # ./generate_entity_patterns.sh -> datatype regex
  local dir
  dir=$(dirname "${path}")
  if [[ ${dir} =~ (^|/)(anat|beh|dwi|eeg|emg|fmap|func|ieeg|meg|micr|motion|mrs|nirs|perf|pet|phenotype)$ ]]; then
    arr[datatype]="${BASH_REMATCH[2]}"
  else
    arr[datatype]="NA"
  fi

  # Derivatives pipeline name is the path component immediately following a
  # "derivatives/" directory; NA when the file is not under one.
  if [[ ${path} =~ (^|/)derivatives/([^/]+)/ ]]; then
    arr[derivatives]="${BASH_REMATCH[2]}"
  else
    arr[derivatives]="NA"
  fi

  local name_no_ext="${filename%%.*}"

  # Split into parts separated by _
  IFS='_' read -ra parts <<<"${name_no_ext}"

  # Process middle parts which are _<key>-<value>
  for ((i = 0; i < ${#parts[@]} - 1; i++)); do
    local part="${parts[${i}]}"
    if [[ ${part} =~ ^([^-]+)-(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # Store the key-value pair
      arr["${key}"]="${key}-${value}"
      # Record the order of the key
      key_order+=("${key}")
    fi
  done

  arr[suffix]="${parts[-1]}"

  key_order+=("suffix")
  key_order+=("extension")
  key_order+=("datatype")
  key_order+=("derivatives")
  key_order+=("path")

  # Store the key order in the array
  arr[_key_order]="${key_order[*]}"
}

libBIDSsh_extension_json_rows_to_column_json_path() {
  # Convert JSON file rows into a json_path column in the table data
  # Usage: libBIDSsh_extension_json_rows_to_column_json_path "${table_data}"
  # Returns: Table data with json_path column added through stdout.
  #   Empty lines are ignored. If the table already has a json_path column,
  #   the table is returned unchanged, so a second call has no effect.
  # Example:
  #   updated=$(libBIDSsh_extension_json_rows_to_column_json_path "$data")
  local table_data="$1"

  awk -F'\t' '
  BEGIN {
    OFS = "\t";
  }

  NR == 1 {
    # Capture header, get column indexes
    for (i = 1; i <= NF; i++) {
      col = tolower($i);
      header_map[col] = i;
      headers[i] = $i;
    }

    ext_idx  = header_map["extension"];
    path_idx = header_map["path"];

    if (!ext_idx || !path_idx) {
      print "Error: Required columns (extension, path) not found" > "/dev/stderr";
      exit 1;
    }

    if ("json_path" in header_map) {
      # Already processed: pass the table through unchanged
      passthrough = 1;
      print $0;
      next;
    }

    print $0, "json_path";  # add json_path column
    next;
  }

  passthrough {
    print $0;
    next;
  }

  # Skip empty lines (for example a trailing newline)
  NF == 0 { next; }

  {
    row[NR] = $0;
    extension = $ext_idx;
    path = $path_idx;

    # Construct key by all fields except extension and path
    key = "";
    for (i = 1; i <= NF; i++) {
      if (i != ext_idx && i != path_idx) key = key "|" $i;
    }

    row_key[NR] = key;
    row_ext[NR] = extension;
    row_path[NR] = path;

    if (tolower(extension) == "json") {
      json_path[key] = path;
      json_row[NR] = 1;
    } else {
      has_non_json[key] = 1;
    }

    line_nums[NR] = 1;
  }

  END {
    if (passthrough) exit;
    for (ln = 2; ln <= NR; ln++) {
      if (!(ln in line_nums)) continue;  # skipped empty line
      key = row_key[ln];
      is_json = (ln in json_row);
      has_match = (key in has_non_json);

      if (is_json && has_match) {
        # Drop matched json row
        continue;
      }

      if (is_json && !has_match) {
        print row[ln], row_path[ln];  # unmatched json
      } else if (!is_json && (key in json_path)) {
        print row[ln], json_path[key];  # matched non-json
      } else {
        print row[ln], "NA";  # no json available
      }
    }
  }
  ' <<<"$table_data"
}

_libBIDSsh_load_custom_entities() {
  # Load custom entities from JSON configuration files
  # JSON files should be placed in ./custom directory
  # Each JSON file should contain an "entities" array with objects having:
  #   - key: entity key, the short filename token (e.g. "bp")
  #   - name: entity name, the long table column header (e.g. "bodypart")
  #   - pattern: bash glob pattern for matching

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local plugin_dir="${script_dir}/custom"
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for custom entity support" >&2
    return 1
  fi

  # Initialize global arrays if not already defined
  if [[ -z "${CUSTOM_ENTITIES+x}" ]]; then
    declare -gA CUSTOM_ENTITIES
  fi
  CUSTOM_ENTITIES=()
  if [[ -z "${CUSTOM_ENTITY_KEYS+x}" ]]; then
    declare -ga CUSTOM_ENTITY_KEYS
  fi
  CUSTOM_ENTITY_KEYS=()
  if [[ -z "${CUSTOM_ENTITY_NAMES+x}" ]]; then
    declare -ga CUSTOM_ENTITY_NAMES
  fi
  CUSTOM_ENTITY_NAMES=()

  if [[ ! -d "$plugin_dir" ]]; then
    return 0
  fi

  shopt -s nullglob
  local json_files=("$plugin_dir"/*.json)
  shopt -u nullglob

  if ((${#json_files[@]} == 0)); then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for custom entity support" >&2
    return 1
  fi

  shopt -s nullglob
  for json_file in "${json_files[@]}"; do
    if [[ -f "$json_file" ]]; then
      # Parse JSON and extract entity definitions
      while IFS=';' read -r key name pattern; do
        if [[ -n "$key" && -n "$name" && -n "$pattern" ]]; then
          CUSTOM_ENTITIES["$key"]="$pattern"
          CUSTOM_ENTITY_KEYS+=("$key")
          CUSTOM_ENTITY_NAMES+=("$name")
        fi
      done < <(
        jq -r '.entities[] | "\(.key);\(.name);\(.pattern)"' \
          "$json_file" 2>/dev/null
      )
    fi
  done
  shopt -u nullglob
}

# shellcheck disable=SC2154
_libBIDSsh_compile_bidsignore_line() {
  # Compile one gitignore-style pattern into an anchored ERE and append it to the
  # module-level _LIBBIDSSH_BIDSIGNORE_REGEX / _LIBBIDSSH_BIDSIGNORE_NEG arrays.
  # Blank lines and comments are skipped. Implements the gitignore subset:
  #   - leading '!'        -> negation (re-include), recorded in the NEG array
  #   - leading/embedded / -> anchored to the dataset root
  #   - trailing /         -> directory-only match
  #   - '**' as a whole path segment spans directories; '*' and '?' do not
  #   - '[...]' bracket expressions and '\'-escapes are passed through
  # Usage: _libBIDSsh_compile_bidsignore_line "<pattern>"
  local line="$1"

  # Strip a trailing carriage return (CRLF files).
  line="${line%$'\r'}"
  [[ -z "$line" ]] && return 0

  # Strip unescaped trailing whitespace (an escaped '\ ' trailing space is kept).
  while [[ "$line" == *[[:space:]] && "$line" != *'\'[[:space:]] ]]; do
    line="${line%?}"
  done
  [[ -z "$line" ]] && return 0

  # Escapes, comments and negation at the start of the pattern.
  local negated=0
  case "$line" in
    '\#'* | '\!'*) line="${line#\\}" ;; # literal leading '#' or '!'
    '#'*) return 0 ;;                    # comment
    '!'*)
      negated=1
      line="${line#!}"
      ;;
  esac
  [[ -z "$line" ]] && return 0

  # Trailing slash => directory-only match.
  local dir_only=0
  if [[ "$line" == */ ]]; then
    dir_only=1
    line="${line%/}"
  fi
  [[ -z "$line" ]] && return 0

  # A '/' at the start or middle anchors the pattern to the dataset root.
  local anchored=0
  if [[ "$line" == /* ]]; then
    anchored=1
    line="${line#/}"
  elif [[ "$line" == */* ]]; then
    anchored=1
  fi
  [[ -z "$line" ]] && return 0

  # Translate the glob body into an ERE, character by character.
  local core="" i=0 n=${#line} c nc
  while ((i < n)); do
    c="${line:i:1}"
    if [[ "$c" == '\' ]]; then
      # Backslash escapes the next character -> emit it literally.
      nc="${line:i+1:1}"
      if [[ -n "$nc" ]]; then
        case "$nc" in
          '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '[' | ']' | '*' | '?' | '\')
            core+="\\$nc" ;;
          *) core+="$nc" ;;
        esac
        i=$((i + 2))
      else
        core+='\\'
        i=$((i + 1))
      fi
      continue
    fi
    if [[ "$c" == '*' ]]; then
      if [[ "${line:i+1:1}" == '*' ]]; then
        # A '**' that forms a whole path segment spans directories.
        local prev_ok=0 next_ok=0
        { ((i == 0)) || [[ "${line:i-1:1}" == '/' ]]; } && prev_ok=1
        { ((i + 2 == n)) || [[ "${line:i+2:1}" == '/' ]]; } && next_ok=1
        if ((prev_ok && next_ok)); then
          if ((i + 2 == n)); then
            core+='.*' # trailing '**' matches everything below
            i=$((i + 2))
          else
            core+='(.*/)?' # '**/' matches zero or more directories
            i=$((i + 3))   # also consume the following '/'
          fi
          continue
        fi
      fi
      core+='[^/]*' # single '*' does not cross directory separators
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == '?' ]]; then
      core+='[^/]'
      i=$((i + 1))
      continue
    fi
    if [[ "$c" == '[' ]]; then
      # Copy a bracket expression through, translating a leading '!' to '^'.
      local j=$((i + 1)) bracket='['
      if [[ "${line:j:1}" == '!' || "${line:j:1}" == '^' ]]; then
        bracket+='^'
        j=$((j + 1))
      fi
      [[ "${line:j:1}" == ']' ]] && {
        bracket+=']'
        j=$((j + 1))
      }
      while ((j < n)) && [[ "${line:j:1}" != ']' ]]; do
        bracket+="${line:j:1}"
        j=$((j + 1))
      done
      if ((j < n)); then
        core+="${bracket}]"
        i=$((j + 1))
      else
        core+='\[' # no closing ']': treat '[' literally
        i=$((i + 1))
      fi
      continue
    fi
    # Literal character: escape ERE metacharacters.
    case "$c" in
      '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '\') core+="\\$c" ;;
      *) core+="$c" ;;
    esac
    i=$((i + 1))
  done

  local start end
  if ((anchored)); then start='^'; else start='(^|.*/)'; fi
  if ((dir_only)); then end='/'; else end='(/|$)'; fi

  _LIBBIDSSH_BIDSIGNORE_REGEX+=("${start}${core}${end}")
  _LIBBIDSSH_BIDSIGNORE_NEG+=("$negated")
}

_libBIDSsh_compile_bidsignore() {
  # Compile the built-in default ignores plus a dataset's root .bidsignore into the
  # module-level _LIBBIDSSH_BIDSIGNORE_REGEX / _LIBBIDSSH_BIDSIGNORE_NEG arrays, in
  # match order. Safe to call repeatedly (arrays are reset each time). Only the
  # root-level .bidsignore is read (no inheritance), matching bids-validator.
  # Usage: _libBIDSsh_compile_bidsignore "<bidspath>" [use_defaults=1]
  local bidspath="$1"
  local use_defaults="${2:-1}"

  _LIBBIDSSH_BIDSIGNORE_REGEX=()
  _LIBBIDSSH_BIDSIGNORE_NEG=()

  # Built-in defaults, mirroring bids-validator's addDefaults list. Note that
  # derivatives/ is intentionally NOT ignored (libBIDS treats it as first-class).
  if [[ "$use_defaults" == "1" ]]; then
    local default_pattern
    for default_pattern in '.git**' '.*' 'sourcedata/' 'code/' 'stimuli/' 'log/'; do
      _libBIDSsh_compile_bidsignore_line "$default_pattern"
    done
  fi

  local ignore_file="${bidspath%/}/.bidsignore"
  if [[ -f "$ignore_file" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      _libBIDSsh_compile_bidsignore_line "$line"
    done <"$ignore_file"
  fi
}

_libBIDSsh_path_is_ignored() {
  # Test a dataset-root-relative path against the compiled .bidsignore patterns.
  # Returns 0 if the path is ignored, 1 otherwise. Last matching pattern wins, so
  # a later negation ('!') re-includes a path excluded by an earlier pattern.
  # Usage: _libBIDSsh_path_is_ignored "<relative/path>"
  local relpath="$1"
  local is_ignored=0 idx regex
  for ((idx = 0; idx < ${#_LIBBIDSSH_BIDSIGNORE_REGEX[@]}; idx++)); do
    regex="${_LIBBIDSSH_BIDSIGNORE_REGEX[idx]}"
    if [[ "$relpath" =~ $regex ]]; then
      if [[ "${_LIBBIDSSH_BIDSIGNORE_NEG[idx]}" == "1" ]]; then
        is_ignored=0
      else
        is_ignored=1
      fi
    fi
  done
  ((is_ignored)) && return 0
  return 1
}

libBIDSsh_apply_bidsignore() {
  # Drop rows whose file is excluded by a dataset's .bidsignore (and, by default,
  # the built-in default ignores). Pipeline-style: TSV in -> filtered TSV out.
  # Usage: libBIDSsh_apply_bidsignore "${table_data}" "<bidspath>" [--no-default-ignores]
  # Example:
  #   table=$(libBIDSsh_apply_bidsignore "$table" path/to/dataset)
  local table_data="$1"
  local bidspath="$2"
  shift 2
  local use_defaults=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default-ignores) use_defaults=1; shift ;;
      --no-default-ignores) use_defaults=0; shift ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  _libBIDSsh_compile_bidsignore "$bidspath" "$use_defaults"

  local norm_bidspath
  norm_bidspath=$(tr -s / <<<"${bidspath%/}")

  local line lineno=0 path_idx=-1
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if ((lineno == 1)); then
      local -a hcols
      IFS=$'\t' read -r -a hcols <<<"$line"
      local hi
      for hi in "${!hcols[@]}"; do
        [[ "${hcols[hi]}" == "path" ]] && {
          path_idx=$hi
          break
        }
      done
      if ((path_idx < 0)); then
        echo "Error: no 'path' column in table data" >&2
        return 1
      fi
      printf '%s\n' "$line"
      continue
    fi
    local -a cols
    IFS=$'\t' read -r -a cols <<<"$line"
    local norm_p relpath
    norm_p=$(tr -s / <<<"${cols[path_idx]}")
    relpath="${norm_p#"${norm_bidspath}"/}"
    if ! _libBIDSsh_path_is_ignored "$relpath"; then
      printf '%s\n' "$line"
    fi
  done <<<"$table_data"
}

libBIDSsh_parse_bids_to_table() {
  # Parse a BIDS directory structure into TSV format
  # Usage: libBIDSsh_parse_bids_to_table [OPTIONS] "/path/to/bids/dataset"
  # Options:
  #   --no-bidsignore        do not honor the dataset's .bidsignore or defaults
  #   --no-default-ignores   honor .bidsignore but skip the built-in default ignores
  # Returns: TSV data through stdout with columns for each BIDS entity
  # Example:
  #   bids_table=$(libBIDSsh_parse_bids_to_table "/path/to/bids")
  local bidspath=""
  local honor_bidsignore=1
  local use_defaults=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bidsignore) honor_bidsignore=1; shift ;;
      --no-bidsignore) honor_bidsignore=0; shift ;;
      --default-ignores) use_defaults=1; shift ;;
      --no-default-ignores) use_defaults=0; shift ;;
      --)
        # End of options: everything after is positional (allows a path like "-x").
        shift
        while [[ $# -gt 0 ]]; do
          if [[ -z "$bidspath" ]]; then
            bidspath="$1"
          else
            echo "Error: unexpected extra argument '$1'" >&2
            return 1
          fi
          shift
        done
        ;;
      -*) echo "Unknown option: $1" >&2; return 1 ;;
      *)
        if [[ -z "$bidspath" ]]; then
          bidspath="$1"
        else
          echo "Error: unexpected extra argument '$1'" >&2
          return 1
        fi
        shift
        ;;
    esac
  done
  if [[ ! -d "$bidspath" ]]; then
    echo "Error: Directory '$bidspath' does not exist" >&2
    return 1
  fi

  # Build the pattern piece by piece
  local base_pattern="*"

  # Load custom entities from plugins
  _libBIDSsh_load_custom_entities

  # Entities components
  # Extracted from schema with generate_entity_patterns.sh
  local entities=(
    "*(_sub-+([a-zA-Z0-9]))"
    "*(_tpl-+([a-zA-Z0-9]))"
    "*(_ses-+([a-zA-Z0-9]))"
    "*(_cohort-+([a-zA-Z0-9]))"
    "*(_sample-+([a-zA-Z0-9]))"
    "*(_task-+([a-zA-Z0-9]))"
    "*(_tracksys-+([a-zA-Z0-9]))"
    "*(_acq-+([a-zA-Z0-9]))"
    "*(_nuc-+([a-zA-Z0-9]))"
    "*(_voi-+([a-zA-Z0-9]))"
    "*(_ce-+([a-zA-Z0-9]))"
    "*(_trc-+([a-zA-Z0-9]))"
    "*(_stain-+([a-zA-Z0-9]))"
    "*(_rec-+([a-zA-Z0-9]))"
    "*(_dir-+([a-zA-Z0-9]))"
    "*(_run-+([0-9]))"
    "*(_mod-+([a-zA-Z0-9]))"
    "*(_echo-+([0-9]))"
    "*(_flip-+([0-9]))"
    "*(_inv-+([0-9]))"
    "*(_mt-+([a-zA-Z0-9]))"
    "*(_part-+([a-zA-Z0-9]))"
    "*(_proc-+([a-zA-Z0-9]))"
    "*(_hemi-+([a-zA-Z0-9]))"
    "*(_space-+([a-zA-Z0-9]))"
    "*(_split-+([0-9]))"
    "*(_recording-+([a-zA-Z0-9]))"
    "*(_chunk-+([0-9]))"
    "*(_atlas-+([a-zA-Z0-9]))"
    "*(_seg-+([a-zA-Z0-9]))"
    "*(_scale-+([a-zA-Z0-9]))"
    "*(_res-+([a-zA-Z0-9]))"
    "*(_den-+([a-zA-Z0-9]))"
    "*(_label-+([a-zA-Z0-9]))"
    "*(_desc-+([a-zA-Z0-9]))"
  )

  # Add custom entities from plugins
  for entity_pattern in ${CUSTOM_ENTITIES[@]+"${CUSTOM_ENTITIES[@]}"}; do
    entities+=("$entity_pattern")
  done

  # Suffixes from schema.json
  # jq -r .objects.suffixes.[].value schema.json | paste -s -d'|'
  local suffixes="_@(2PE|ADC|BF|Chimap|CARS|CONF|DIC|DF|FA|FLAIR|FLASH|FLUO|IRT1|M0map|MEGRE|MESE|MP2RAGE|MPE|MPM|MTR|MTRmap|MTS|MTVmap|MTsat|MWFmap|NLO|OCT|PC|PD|PDT2|PDmap|PDw|PLI|R1map|R2map|R2starmap|RB1COR|RB1map|S0map|SEM|SPIM|SR|T1map|T1rho|T1w|T2map|T2star|T2starmap|T2starw|T2w|TB1AFI|TB1DAM|TB1EPI|TB1RFM|TB1SRGE|TB1TFL|TB1map|TEM|UNIT1|VFA|angio|asl|aslcontext|asllabeling|beh|blood|bold|cbv|channels|colFA|coordsystem|defacemask|description|descriptions|dseg|dwi|eeg|electrodes|emg|epi|events|expADC|fieldmap|headshape|XPCT|ieeg|inplaneT1|inplaneT2|m0scan|magnitude|magnitude1|magnitude2|markers|mask|meg|motion|mrsi|mrsref|nirs|noRF|optodes|pet|phase|phase1|phase2|phasediff|photo|physio|physioevents|probseg|sbref|scans|sessions|stim|svs|trace|uCT|unloc)"

  # Allowed extensions
  # jq -r .objects.extensions.[].value schema.json | paste -s -d'|'
  # Stripped the ".*" and directory entries manually
  local extensions="@(.ave|.bdf|.bval|.bvec|.chn|.con|.dat|.ds|.dlabel.nii|.edf|.eeg|.fdt|.fif|.jpg|.json|.kdf|.label.gii|.md|.mefd|.mhd|.mrk|.ome.zarr|.nii|.nii.gz|.nwb|.ome.btf|.ome.tif|.png|.pos|.raw|.rst|.set|.snirf|.sqd|.tif|.trg|.tsv|.tsv.gz|.txt|.vhdr|.vmrk)"

  # Piece together the pattern
  local pattern=${base_pattern}
  for entry in "${entities[@]}"; do
    pattern+=${entry}
  done
  pattern+=${suffixes}
  pattern+=${extensions}

  shopt -s extglob
  shopt -s nullglob
  shopt -s globstar

  # shellcheck disable=SC2206
  local files=("${bidspath}"/**/${pattern})

  shopt -u extglob
  shopt -u nullglob
  shopt -u globstar

  # Drop files excluded by the dataset's .bidsignore (and built-in default
  # ignores) unless disabled. Paths are matched relative to the dataset root.
  if ((honor_bidsignore)); then
    _libBIDSsh_compile_bidsignore "$bidspath" "$use_defaults"
    if ((${#_LIBBIDSSH_BIDSIGNORE_REGEX[@]} > 0)); then
      local norm_bidspath
      norm_bidspath=$(tr -s / <<<"${bidspath%/}")
      local -a kept_files=()
      local f relpath
      for f in ${files[@]+"${files[@]}"}; do
        relpath=$(tr -s / <<<"$f")
        relpath="${relpath#"${norm_bidspath}"/}"
        if ! _libBIDSsh_path_is_ignored "$relpath"; then
          kept_files+=("$f")
        fi
      done
      if ((${#kept_files[@]})); then
        files=("${kept_files[@]}")
      else
        files=()
      fi
    fi
  fi

  # Order of entities from generate_entity_patterns.sh.
  # entities_order holds entity keys (filename tokens); entities_name_order holds
  # entity names (the long, canonical column headers). Both in canonical BIDS order.
  entities_name_order=$'subject\ttemplate\tsession\tcohort\tsample\ttask\ttracksys\tacquisition\tnucleus\tvolume\tceagent\ttracer\tstain\treconstruction\tdirection\trun\tmodality\techo\tflip\tinversion\tmtransfer\tpart\tprocessing\themisphere\tspace\tsplit\trecording\tchunk\tatlas\tsegmentation\tscale\tresolution\tdensity\tlabel\tdescription'
  entities_order="sub tpl ses cohort sample task tracksys acq nuc voi ce trc stain rec dir run mod echo flip inv mt part proc hemi space split recording chunk atlas seg scale res den label desc"

  # Add custom entities to ordering
  for entity_key in ${CUSTOM_ENTITY_KEYS[@]+"${CUSTOM_ENTITY_KEYS[@]}"}; do
    entities_order+=" $entity_key"
  done

  for entity_name in ${CUSTOM_ENTITY_NAMES[@]+"${CUSTOM_ENTITY_NAMES[@]}"}; do
    entities_name_order+=$'\t'"$entity_name"
  done

  printf "derivatives\tdatatype\t%s\tsuffix\textension\tpath\n" "${entities_name_order}"
  for file in ${files[@]+"${files[@]}"}; do
    declare -A file_info
    _libBIDSsh_parse_filename "${file}" file_info
    for key in derivatives datatype ${entities_order} suffix extension path; do
      if [[ "${file_info[${key}]+abc}" ]]; then
        printf '%s\t' "${file_info[${key}]}"
      else
        printf 'NA\t'
      fi
    done
    echo ""
  done | sed $'s/\t*$//'
}

libBIDSsh_table_column_to_array() {
  # Extract a column from table data into a bash array
  # Usage: libBIDSsh_table_column_to_array "${table_data}" "column_name" array_ref [unique] [exclude_NA]
  # Arguments:
  #   table_data: TSV-formatted string
  #   column_name: Name or index (1..number of columns) of column to extract
  #   array_ref: Name of array variable to populate (declare -a)
  #   unique: (optional) "true" to return only unique values (default: true)
  #   exclude_NA: (optional) "true" to exclude NA values (default: true)
  # Returns: 0 on success, also when no values remain (empty array);
  #   1 if the column is not in the header
  # Example:
  #   declare -a subjects
  #   libBIDSsh_table_column_to_array "$data" "subject" subjects true true
  # All internal names have the _libbidssh_c2a_ prefix, so that they cannot
  # hide the caller's variables or the array given by name in array_ref.
  if [[ "$3" == _libbidssh_c2a_* ]]; then
    echo "Error: array name '$3' is reserved" >&2
    return 1
  fi
  local _libbidssh_c2a_column="$2"
  local -n _libbidssh_c2a_ref="$3" # nameref to the array variable
  local _libbidssh_c2a_unique="${4:-true}"
  local _libbidssh_c2a_exclude_NA="${5:-true}"
  local _libbidssh_c2a_values
  local _libbidssh_c2a_line
  local -A _libbidssh_c2a_seen=()

  # Clear the array in case it's not empty
  _libbidssh_c2a_ref=()

  # Use awk to extract the column (skipping header row). awk exits 1 if the
  # column is not in the header. Otherwise it prints a final "." line, so
  # that the command substitution keeps empty values at the end.
  if ! _libbidssh_c2a_values=$(awk -v col="${_libbidssh_c2a_column}" '
        BEGIN { FS="\t" }
        NR == 1 {
            col_idx = 0
            if (col ~ /^[0-9]+$/) {
                if (col + 0 >= 1 && col + 0 <= NF) col_idx = col + 0
            } else {
                for (i = 1; i <= NF; i++) {
                    if ($i == col) {
                        col_idx = i
                        break
                    }
                }
            }
            if (!col_idx) {
                not_found = 1
                exit 1
            }
            next  # Skip header row
        }
        NF == 0 { next }  # Skip empty lines (e.g. a trailing newline)
        { print $col_idx }
        END {
            if (not_found) exit 1
            print "."
        }
    ' <<<"$1"); then
    echo "Error: Column '${_libbidssh_c2a_column}' not found" >&2
    return 1
  fi
  _libbidssh_c2a_values="${_libbidssh_c2a_values%.}"

  while IFS= read -r _libbidssh_c2a_line; do
    # Skip NA entries if exclude_NA is true
    if [[ "${_libbidssh_c2a_exclude_NA}" == "true" &&
      "${_libbidssh_c2a_line}" == "NA" ]]; then
      continue
    fi
    # Apply unique filter if requested. The "k" prefix makes the key
    # non-empty, because bash does not accept an empty subscript.
    if [[ "${_libbidssh_c2a_unique}" == "true" ]]; then
      if [[ -n "${_libbidssh_c2a_seen["k${_libbidssh_c2a_line}"]+x}" ]]; then
        continue
      fi
      _libbidssh_c2a_seen["k${_libbidssh_c2a_line}"]=1
    fi
    _libbidssh_c2a_ref+=("${_libbidssh_c2a_line}")
  done < <(printf '%s' "${_libbidssh_c2a_values}")
}

# Module-level state of libBIDSsh_table_iterator, keyed by the name of the
# caller's row array. SIG holds the sort arguments and TABLE the table of the
# active iteration, POS the index of the next row, COUNT the number of rows,
# HEADER the header line, and ROWS the sorted data lines (key "<name>:<index>").
declare -gA _LIBBIDSSH_ITER_SIG=()
declare -gA _LIBBIDSSH_ITER_TABLE=()
declare -gA _LIBBIDSSH_ITER_POS=()
declare -gA _LIBBIDSSH_ITER_COUNT=()
declare -gA _LIBBIDSSH_ITER_HEADER=()
declare -gA _LIBBIDSSH_ITER_ROWS=()

_libBIDSsh_iterator_clear() {
  # Remove the cached state of libBIDSsh_table_iterator for one row array.
  # Usage: _libBIDSsh_iterator_clear "<array_name>"
  local _lbit_name="$1"
  local _lbit_count="${_LIBBIDSSH_ITER_COUNT[${_lbit_name}]:-0}"
  local _lbit_i
  for ((_lbit_i = 0; _lbit_i < _lbit_count; _lbit_i++)); do
    unset "_LIBBIDSSH_ITER_ROWS[${_lbit_name}:${_lbit_i}]"
  done
  unset "_LIBBIDSSH_ITER_SIG[${_lbit_name}]" "_LIBBIDSSH_ITER_TABLE[${_lbit_name}]" \
    "_LIBBIDSSH_ITER_POS[${_lbit_name}]" \
    "_LIBBIDSSH_ITER_COUNT[${_lbit_name}]" "_LIBBIDSSH_ITER_HEADER[${_lbit_name}]"
}

libBIDSsh_table_iterator() {
  # Iterate through table data row by row, in sorted order
  # Usage: libBIDSsh_table_iterator "${table_data}" arr_ref [sort_columns...] [-r]
  # Arguments:
  #   table_data: TSV-formatted string
  #   arr_ref: Name of associative array to populate with each row's data
  #   sort_columns: (optional) Columns to sort by (multiple allowed). With no
  #     sort columns, rows are sorted by all columns, left to right.
  #   -r: (optional) Reverse sort order
  # Sorting always uses "sort --version-sort". Table order is not kept.
  # Returns: 0 for success (more rows), 1 when done
  # State: the sorted rows and the cursor are kept in module-level
  #   _LIBBIDSSH_ITER_* arrays, keyed by the name of arr_ref, and not in arr_ref.
  #   The first call (or a call with a different table or different sort
  #   arguments) sorts the table once. Each later call returns the next row.
  #   After the last row the state is removed, so a new loop starts again.
  #   After a "break", a new loop with the same array, table and sort arguments
  #   continues after the last row. To start again from the first row, empty
  #   the array first (row=()), or call the function once with an empty table
  #   (libBIDSsh_table_iterator "" row || true). An inner loop that runs while
  #   an outer loop is active must use a different array name. Do not change
  #   the table string inside the loop body: a changed table starts again from
  #   the first row. After a "break", the state (a copy of the table and its
  #   sorted rows) stays in memory until the next call with that array name;
  #   use one of the resets above to remove it. A new array (for example
  #   "local -A row" in a function) also starts again. Do not use "unset row"
  #   alone as a reset: declare the array again after it (declare -A row).
  #   Array names that start with "_lbit_" are reserved.
  # Cost: each call gets the table by value and compares it with the saved
  #   table, so each call still takes time in proportion to the table size.
  # Example:
  #   declare -A row
  #   while libBIDSsh_table_iterator "$data" row "subject" "session" -r; do
  #     echo "Processing subject ${row[subject]} session ${row[session]}"
  #   done
  if [[ -z "${2:-}" ]]; then
    echo "Error: Missing array reference argument" >&2
    return 1
  fi
  # Local variables use the private prefix "_lbit_", so that they do not hide
  # the caller's array from the name reference. Refuse names with this prefix.
  if [[ "$2" == _lbit_* ]]; then
    echo "Error: Array name '$2' uses the reserved prefix '_lbit_'" >&2
    return 1
  fi
  local _lbit_arr_name="$2"
  local -n _lbit_arr_ref=$2 # Name reference to the associative array

  local _lbit_arg _lbit_col _lbit_i _lbit_idx _lbit_line
  local _lbit_args_sig=""
  for _lbit_arg in "${@:3}"; do
    _lbit_args_sig+=$'\x1f'"${_lbit_arg}"
  done

  # Continue the active iteration only if the sort arguments and the table are
  # the same, and the caller did not empty the array since the last call.
  # "${arr[*]+x}" is empty for an empty array and for a declared array that
  # has no value ("local -A row"), and is safe under "set -u".
  # The table is compared last, with "[" (a plain string compare), because a
  # compare of a large table is the slowest step of a call.
  local _lbit_resume=false
  if [[ -n "${_LIBBIDSSH_ITER_SIG[${_lbit_arr_name}]+x}" &&
    "${_LIBBIDSSH_ITER_SIG[${_lbit_arr_name}]}" == "${_lbit_args_sig}" &&
    -n "${_lbit_arr_ref[*]+x}" ]] &&
    [ "${1:-}" = "${_LIBBIDSSH_ITER_TABLE[${_lbit_arr_name}]}" ]; then
    _lbit_resume=true
  fi

  # Start a new iteration: split the table and sort the rows once
  if [[ "${_lbit_resume}" == false ]]; then
    _libBIDSsh_iterator_clear "${_lbit_arr_name}"
    local _lbit_table_data="${1:-}"
    shift 2 # Remaining arguments are sort columns or options

    # Empty input: nothing to iterate (this also resets the state)
    if [[ -z "${_lbit_table_data}" ]]; then
      _lbit_arr_ref=()
      return 1
    fi

    # Handle options
    local _lbit_reverse_sort=false
    local -a _lbit_sort_columns=()
    for _lbit_arg in "$@"; do
      if [[ "$_lbit_arg" == "-r" ]]; then
        _lbit_reverse_sort=true
      else
        _lbit_sort_columns+=("$_lbit_arg")
      fi
    done

    # Read all lines into an array (empty lines are dropped)
    local -a _lbit_lines=()
    IFS=$'\n' read -d '' -r -a _lbit_lines <<<"${_lbit_table_data}" || true

    # Handle empty input
    if [[ ${#_lbit_lines[@]} -eq 0 ]]; then
      _lbit_arr_ref=()
      return 1
    fi

    # Extract header and data lines
    local _lbit_header="${_lbit_lines[0]}"
    local -a _lbit_data_lines=("${_lbit_lines[@]:1}")
    local -a _lbit_headers=()
    _lbit_line="${_lbit_header//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r -a _lbit_headers <<<"${_lbit_line}"

    # A header with no column names gives no keys to set
    if [[ -z "${_lbit_header//$'\t'/}" ]]; then
      _lbit_arr_ref=()
      return 1
    fi

    # Build sort keys (-k options for sort, 1-based). With no sort columns,
    # sort by all columns left to right.
    local -a _lbit_sort_keys=()
    if ((${#_lbit_sort_columns[@]} > 0)); then
      local -A _lbit_column_indices=()
      for _lbit_i in "${!_lbit_headers[@]}"; do
        if [[ -n "${_lbit_headers[_lbit_i]}" ]]; then
          _lbit_column_indices["${_lbit_headers[_lbit_i]}"]=${_lbit_i}
        fi
      done
      for _lbit_col in "${_lbit_sort_columns[@]}"; do
        if [[ -n "${_lbit_col}" && -n "${_lbit_column_indices[${_lbit_col}]+x}" ]]; then
          _lbit_idx=$((_lbit_column_indices["${_lbit_col}"] + 1))
          _lbit_sort_keys+=("-k$_lbit_idx,$_lbit_idx")
        else
          echo "Error: Column '${_lbit_col}' not found in header" >&2
          return 1
        fi
      done
    else
      for _lbit_i in "${!_lbit_headers[@]}"; do
        _lbit_idx=$((_lbit_i + 1))
        _lbit_sort_keys+=("-k$_lbit_idx,$_lbit_idx")
      done
    fi

    # Add reverse flag if needed
    local -a _lbit_sort_reverse_flag=()
    if [[ "$_lbit_reverse_sort" == true ]]; then
      _lbit_sort_reverse_flag=("-r")
    fi

    # Sort the data lines once (handle empty case)
    local -a _lbit_sorted_data=()
    if [[ ${#_lbit_data_lines[@]} -gt 0 ]]; then
      readarray -t _lbit_sorted_data < <(
        printf "%s\n" "${_lbit_data_lines[@]}" |
          sort --version-sort -t$'\t' ${_lbit_sort_reverse_flag[@]+"${_lbit_sort_reverse_flag[@]}"} ${_lbit_sort_keys[@]+"${_lbit_sort_keys[@]}"}
      ) || true
    fi

    # No data rows: nothing to iterate
    if [[ ${#_lbit_sorted_data[@]} -eq 0 ]]; then
      _lbit_arr_ref=()
      return 1
    fi

    # Store the state for the next calls
    for _lbit_i in "${!_lbit_sorted_data[@]}"; do
      _LIBBIDSSH_ITER_ROWS["${_lbit_arr_name}:${_lbit_i}"]="${_lbit_sorted_data[_lbit_i]}"
    done
    _LIBBIDSSH_ITER_COUNT["${_lbit_arr_name}"]=${#_lbit_sorted_data[@]}
    _LIBBIDSSH_ITER_HEADER["${_lbit_arr_name}"]="${_lbit_header}"
    _LIBBIDSSH_ITER_POS["${_lbit_arr_name}"]=0
    _LIBBIDSSH_ITER_SIG["${_lbit_arr_name}"]="${_lbit_args_sig}"
    _LIBBIDSSH_ITER_TABLE["${_lbit_arr_name}"]="${_lbit_table_data}"
  fi

  local _lbit_current_line="${_LIBBIDSSH_ITER_POS[${_lbit_arr_name}]}"
  local _lbit_row_count="${_LIBBIDSSH_ITER_COUNT[${_lbit_arr_name}]}"

  # If we're at the end, remove the state and return failure
  if ((_lbit_current_line >= _lbit_row_count)); then
    _libBIDSsh_iterator_clear "${_lbit_arr_name}"
    _lbit_arr_ref=()
    return 1
  fi

  # Split the header and the current row on tabs. A non-whitespace IFS keeps
  # empty fields, so values do not move to a different column.
  local -a _lbit_row_headers=() _lbit_values=()
  _lbit_line="${_LIBBIDSSH_ITER_HEADER[${_lbit_arr_name}]//$'\t'/$'\x1f'}"
  IFS=$'\x1f' read -r -a _lbit_row_headers <<<"${_lbit_line}"
  _lbit_line="${_LIBBIDSSH_ITER_ROWS[${_lbit_arr_name}:${_lbit_current_line}]//$'\t'/$'\x1f'}"
  IFS=$'\x1f' read -r -a _lbit_values <<<"${_lbit_line}"

  # Store key-value pairs in the array (read drops a trailing empty field)
  _lbit_arr_ref=()
  for _lbit_i in "${!_lbit_row_headers[@]}"; do
    [[ -n "${_lbit_row_headers[_lbit_i]}" ]] || continue
    if [[ -n "${_lbit_values[_lbit_i]+x}" ]]; then
      _lbit_arr_ref["${_lbit_row_headers[_lbit_i]}"]="${_lbit_values[_lbit_i]}"
    else
      _lbit_arr_ref["${_lbit_row_headers[_lbit_i]}"]=""
    fi
  done

  # Move the cursor to the next row
  _LIBBIDSSH_ITER_POS["${_lbit_arr_name}"]=$((_lbit_current_line + 1))

  return 0
}

# shellcheck disable=SC2178
libBIDSsh_json_to_associative_array() {
  # Parse a JSON file into a bash associative array
  # Usage: libBIDSsh_json_to_associative_array "file.json" array_ref
  # Arguments:
  #   file.json: Path to JSON file
  #   array_ref: Name of associative array to populate (declare -A)
  # Example:
  #   declare -A json_data
  #   libBIDSsh_json_to_associative_array "file.json" json_data
  local json_file="${1:-}"
  if [[ -z "${2:-}" ]]; then
    echo "Error: Missing array reference argument" >&2
    return 1
  fi
  local array_name="$2"

  if [[ ! -f "$json_file" ]]; then
    echo "Error: File '$json_file' does not exist" >&2
    return 1
  fi
  declare -n arr_ref="$array_name" # nameref to the associative array

  # Use jq to process the JSON file and output key-value pairs with type prefixes
  while IFS="=" read -r key value; do
    # Remove quotes from key (jq outputs keys with quotes)
    key="${key%\"}"
    key="${key#\"}"
    # shellcheck disable=SC2034 # arr_ref is a nameref to the caller's array
    arr_ref["$key"]="$value"
  done < <(jq -r 'to_entries[] |
        "\(.key)=\(
            if .value|type == "array" then "array:" + (.value|join(","))
            elif .value|type == "object" then "object:" + (.value|tostring)
            else (.value|type) + ":" + (.value|tostring)
            end
        )"' "$json_file")
}

# bash "if __main__" implementation
if ! (return 0 2>/dev/null); then
  if [[ $# -eq 0 ]]; then
    echo 'error: the first argument must be a path to a bids dataset'
    exit 1
  fi
  libBIDSsh_parse_bids_to_table "$@"
fi
