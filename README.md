# libBIDS.sh

A bash library used to parse BIDS datasets into a data structure suitable for use in shell pipelines.

Parses a BIDS dataset by:

1. Using bash `extglob` features to find all BIDS-compliant filenames
2. Parsing out the potential subfields of the BIDS file naming scheme into a key-value pairs
3. Constructs a "database" CSV-structured representation of the dataset
4. (TODO) Provides library functions to subset the database based on the fields

Implementation is "permissive" with regards to the BIDS spec, some combinations of optional fields are allowed in
the parser that the BIDS spec does not allow.

## Usage

libBIDS.sh has two use cases.

1. `source libBIDS.sh` in your bash scripts to provide the functions for parsing BIDS data structures
2. Run `libBIDS.sh /path/to/bids/dataset` to output a CSV-formatted representation of the BIDS dataset
