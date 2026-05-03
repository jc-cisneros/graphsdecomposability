#!/bin/bash

# Define your input paths here.
# Paths should be relative to the current module.

INPUT_FILES=(
    ../1_data/output/*
)

# Path to current module
MAKE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Remove existing input directory and recreate it
rm -rf "${MAKE_SCRIPT_DIR}/input"
mkdir -p "${MAKE_SCRIPT_DIR}/input"

# Variable to track if any links were created
links_created=false

# Loop through the input paths
for file_path in "${INPUT_FILES[@]}"; do
    resolved_path="$MAKE_SCRIPT_DIR/$file_path"
    
    if [[ -e "$resolved_path" ]]; then  # check if the path exists
        file_name=$(basename "$resolved_path")
        ln -sfn "../$file_path" "$MAKE_SCRIPT_DIR/input/$file_name" # create symlink in module input dir
        links_created=true
    else
        echo -e "\033[0;31mWarning\033[0m in \033[0;34mget_inputs.sh\033[0m: $file_path does not exist or is not a valid file path." >&2
    fi
done

# Output the result
if [[ "$links_created" == true ]]; then
  echo -e "\nAll input links were created!"
else
    echo -e "\n\033[0;34mNote:\033[0m There were no input links to create in \033[0;34mget_inputs.sh\033[0m."
fi
