#!/bin/bash

unset run_R
run_R () {
    trap - ERR  # allow internal error handling

    # get arguments
    program="$1"
    logfile="$2"
    shift 2                       # now "$@" contains only the script's CLI args
    OUTPUT_DIR="$(dirname "$logfile")"

    # set R command if unset
    if [ -z "$rCmd" ]; then
        echo -e "\nNo R command set. Using default: Rscript"
        rCmd="Rscript"
    fi

    # check if the command exists before running, log error if does not
    if ! command -v "$rCmd" &> /dev/null; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\n\033[0;31mProgram error\033[0m at ${error_time}: ${rCmd} not found. Make sure command line usage is properly set up."
        echo "Program Error at ${error_time}: ${rCmd} not found." >> "${logfile}"
        exit 1
    fi

    # check if the target script exists
    if [ ! -f "${program}" ]; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\n\033[0;31mProgram error\033[0m at ${error_time}: script ${program} not found."
        echo "Program Error at ${error_time}: script ${program} not found." >> "${logfile}"
        exit 1
    fi

    # snapshot of output folder before
    files_before=$(
        find "$OUTPUT_DIR" -type f ! -name "make.log" -print0 \
        | xargs -0 -n1 --no-run-if-empty basename \
        | sort | tr '\n' '\n'
    )

    start_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\nScript ${program} in ${rCmd} started at ${start_time}" | tee -a "${logfile}"

    # run command with forwarded args; capture stdout+stderr
    output=$("$rCmd" "${program}" "$@" 2>&1)
    return_code=$?

    # files after (newer than start_time)
    files_after=$(
        find "$OUTPUT_DIR" -type f -newermt "$start_time" ! -name "make.log" -print0 \
        | xargs -0 -n1 --no-run-if-empty basename \
        | sort | tr '\n' '\n'
    )

    # compute created files (lines present in after but not before)
    # use 'comm' which expects sorted unique lines
    created_files=$(comm -13 <(printf "%s" "$files_before") <(printf "%s" "$files_after"))

    if [ $return_code -ne 0 ]; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\033[0;31mWarning\033[0m: ${program} failed at ${error_time}. Check log for details."
        echo "Error in ${program} at ${error_time}: $output" >> "${logfile}"
        if [ -n "$created_files" ]; then
            echo -e "\033[0;31mWarning\033[0m: there was an error, but files were created. Check log."
            {
              echo
              echo "Warning: There was an error, but these files were created:"
              echo "$created_files"
            } >> "${logfile}"
        fi
        exit 1
    else
        echo "Script ${program} finished successfully at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${logfile}"
        echo "Output: $output" >> "${logfile}"
        if [ -n "$created_files" ]; then
            {
              echo
              echo "The following files were created by ${program}:"
              echo "$created_files"
            } >> "${logfile}"
        fi
    fi
}
