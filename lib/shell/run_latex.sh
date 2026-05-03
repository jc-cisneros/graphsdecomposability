#!/bin/bash

# Ensure we're replacing any existing definition
unset -f run_latex || true
unset -f cleanup || true

run_latex() {
  trap - ERR  # disable external error trap during this function

  # --- Arguments ---
  programname=$(basename "$1" .tex)
  logfile="$2"
  OUTPUT_DIR="${3:-../output}"

  # --- Cleanup handler ---
  cleanup() {
    if [ -f "${programname}.pdf" ]; then
      mv "${programname}.pdf" "${OUTPUT_DIR}"
    fi
    rm -f "${programname}".{aux,log,out,toc,bbl,blg,synctex.gz,nav,snm,fdb_latexmk,fls}
  }
  trap 'cleanup' EXIT

  # --- Check for tectonic ---
  if ! command -v tectonic &> /dev/null; then
    error_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\n\033[0;31mProgram error\033[0m at ${error_time}: tectonic not found. Ensure LaTeX is installed."
    echo "Program Error at ${error_time}: tectonic not found." >> "${logfile}"
    exit 1
  fi
 
    # check if the target script exists
    if [ ! -f "${programname}.tex" ]; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\n\033[0;31mProgram error\033[0m at ${error_time}: script ${programname}.tex not found." 
        echo "Program Error at ${error_time}: script ${programname}.tex not found." >> "${logfile}"
        exit 1
    fi
    
    # capture the content of output folder before running the script
    files_before=$(
    find "$OUTPUT_DIR" -type f ! -name "make.log" -print0 | \
    xargs -0 -n1 --no-run-if-empty basename | tr '\n' ' '
    )
    # log start time for the script
    start_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\nScript ${programname}.tex in latexmk -pdf -bibtex started at ${start_time}" | tee -a "${logfile}"

  # --- Compile ---
  output=$(tectonic --keep-intermediates --synctex --outdir . "${programname}.tex" 2>&1)
  return_code=$?

  # --- Cleanup files, move PDF ---
  cleanup

    # capture the content of output folder after running the script
    files_after=$(
    find "$OUTPUT_DIR" -type f -newermt "$start_time" ! -name "make.log" -print0 | \
    xargs -0 -n1 --no-run-if-empty basename | tr '\n' ' '
    )    
    # determine the new files that were created
    created_files=$(comm -13 <(echo "$files_before") <(echo "$files_after"))

  # --- Handle result ---
  if [ $return_code -ne 0 ]; then
    error_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\033[0;31mWarning\033[0m: ${programname}.tex failed at ${error_time}. Check log for details."
    echo "Error in ${programname}.tex at ${error_time}: $output" >> "${logfile}"
    if [ -n "$created_files" ]; then
      echo -e "\033[0;31mWarning\033[0m: Files were created despite failure. Check output."
      echo "Warning: Created files despite failure: $created_files" >> "${logfile}"
    fi
    exit 1
  else
    echo "Script ${programname}.tex finished successfully at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${logfile}"
    echo "Output: $output" >> "${logfile}"
    if [ -n "$created_files" ]; then
      echo -e "\nThe following files were created in ${programname}.tex:" >> "${logfile}"
      echo "$created_files" >> "${logfile}"
    fi
    if [ ! -f "${OUTPUT_DIR}/${programname}.pdf" ]; then
      echo -e "\033[0;31mWarning\033[0m: No PDF was created. Check output in log."
      echo "Warning: No PDF was created." >> "${logfile}"
    fi
  fi
}
