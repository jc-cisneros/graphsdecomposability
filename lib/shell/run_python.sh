#!/bin/bash   

unset run_python
run_python () {
    trap - ERR # allow internal error handling

    # get arguments
    program="$1"
    logfile="$2"
    shift 2                # remove first two arguments so "$@" contains only the extras
    OUTPUT_DIR=$(dirname "$logfile")

    # set python command if unset
    if [ -z "$pythonCmd" ]; then
        echo -e "\nNo python command set. Using default: python3"
        pythonCmd="python3"
    fi

    # check if the command exists
    if ! command -v ${pythonCmd} &> /dev/null; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\n\033[0;31mProgram error\033[0m at ${error_time}: ${pythonCmd} not found."
        echo "Program Error at ${error_time}: ${pythonCmd} not found." >> "${logfile}"
        exit 1
    fi

    # check if the target script exists
    if [ ! -f "${program}" ]; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\n\033[0;31mProgram error\033[0m at ${error_time}: script ${program} not found."
        echo "Program Error at ${error_time}: script ${program} not found." >> "${logfile}"
        exit 1
    fi

    # capture the content of output folder before running the script
    files_before=$(find "$OUTPUT_DIR" -type f ! -name "make.log" -print0 | \
                   xargs -0 -n1 --no-run-if-empty basename | tr '\n' ' ')

    start_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\nScript ${program} in ${pythonCmd} started at ${start_time}" | tee -a "${logfile}"

    # run command with forwarded args
    output=$(${pythonCmd} -u "${program}" "$@" 2>&1)
    return_code=$?

    # capture new files
    files_after=$(find "$OUTPUT_DIR" -type f -newermt "$start_time" ! -name "make.log" -print0 | \
                  xargs -0 -n1 --no-run-if-empty basename | tr '\n' ' ')
    created_files=$(comm -13 <(echo "$files_before") <(echo "$files_after"))

    # report
    if [ $return_code -ne 0 ]; then
        error_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\033[0;31mWarning\033[0m: ${program} failed at ${error_time}. Check log for details."
        echo "Error in ${program} at ${error_time}: $output" >> "${logfile}"
        if [ -n "$created_files" ]; then
            echo -e "\033[0;31mWarning\033[0m: there was an error, but files were created. Check log."
            echo -e "\nWarning: Files created despite error: $created_files" >> "${logfile}"
        fi
        exit 1
    else
        echo "Script ${program} finished successfully at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${logfile}"
        echo "Output: $output" >> "${logfile}"
        if [ -n "$created_files" ]; then
            echo -e "\nThe following files were created in ${program}:" >> "${logfile}"
            echo "$created_files" >> "${logfile}"
        fi
    fi
}
