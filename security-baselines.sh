#!/usr/bin/env bash
#
# This script is used to apply security baselines to a system. 
# It checks for the presence of required tools and applies configurations to enhance system security.
#
# Author: Abdalrahman Bashir(Naksh)
# Date: 2026-11-03
# Usage: ./security-baselines.sh -f <server_list_file> -u <username>

# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command 
# to exit with a non-zero status, or zero if no command exited with a non-zero status.
set -euo pipefail
# Create a temporary log file to store logs
LOG_FILE=$(mktemp /tmp/security_baseline_log.XXXXXX)
readonly LOG_FILE
# Set the SCAP datastream for Rocky Linux 10
readonly SCAP_DATASTREAM="/usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml"
readonly CIS_PROFILE="xccdf_org.ssgproject.content_profile_cis"

log_info() {
    # Log informational messages to both the console and the log file
    echo "[INFO] $1" | tee -a "$LOG_FILE"
}

log_error() {
    # Log error messages to both the console and the log file, redirecting to stderr
    echo "[ERROR] $1" | tee -a "$LOG_FILE" >&2
}

print_usage() {
    # Print usage information for the script
    log_info "Usage: $0 -f <server_list_file> -u <username>"
    log_info "  -f <server_list_file>: Path to the file containing the list of servers to apply security baselines."
    log_info "  -u <username>: Username to use for SSH connections to the servers."
    log_info "  -h: Display this help message."
}

cleanup() {
    # Clean up temporary files and log the cleanup action
    log_info "Cleaning up temporary log file: $LOG_FILE"
    rm -f "$LOG_FILE"
}

check_server(){
    # Check if the server is reachable via ping 
    #and if SSH connection can be established with passwordless sudo privileges
    local server="$1"
    local remote_user="$2"
    log_info "Checking connectivity to server: $server"
    if ping -c 1 "$server" &> /dev/null; then
        log_info "Server $server is reachable via ping."
    else
        log_error "Server $server is not reachable via ping. Skipping."
        return 1
    fi
    
    # Test SSH connectivity and sudo privileges silently
    if ! ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$remote_user@$server" "sudo -n true" 2>/dev/null; then
        log_error "SSH connection failed or user $remote_user lacks passwordless sudo on $server. Skipping."
        return 1
    fi
}

harden_server() {
    # Apply security baselines to the specified server using OpenSCAP
    local server="$1"
    local remote_user="$2"
    local report_dir="reports/${server}_$(date +%F_%H-%M)"
    
    mkdir -p "$report_dir"
    log_info "Created local report directory: $report_dir"

    log_info "Installing OpenSCAP and running pre-hardening scan on $server..."
    ssh -n -o ConnectTimeout=5 "$remote_user@$server" << EOF
        set -euo pipefail
        
        # Install required OpenSCAP tools
        sudo dnf update -y
        sudo dnf install -y openscap-scanner scap-security-guide

        # 1. Pre-Hardening Scan
        # oscap returns 2 if vulnerabilities are found. Catch it so set -e doesn't kill the script.
        sudo oscap xccdf eval \\
            --profile $CIS_PROFILE \\
            --results /tmp/pre-results.xml \\
            --report /tmp/pre-report.html \\
            $SCAP_DATASTREAM || [ \$? -eq 2 ]

        # 2. Hardening Remediation & Post-Scan
        sudo oscap xccdf eval \\
            --remediate \\
            --profile $CIS_PROFILE \\
            --results /tmp/post-results.xml \\
            --report /tmp/post-report.html \\
            $SCAP_DATASTREAM || [ \$? -eq 2 ]

        # 3. Change ownership of the report files to the remote user for easier retrieval
        sudo chown $remote_user:$remote_user /tmp/pre-results.xml /tmp/pre-report.html /tmp/post-results.xml /tmp/post-report.html
EOF
    # Retrieve the pre- and post-hardening reports from the remote server
    log_info "Retrieving pre- and post-hardening reports from $server..."
    scp -q "$remote_user@$server:/tmp/pre-results.xml" "$report_dir/"
    scp -q "$remote_user@$server:/tmp/pre-report.html" "$report_dir/"
    scp -q "$remote_user@$server:/tmp/post-results.xml" "$report_dir/"
    scp -q "$remote_user@$server:/tmp/post-report.html" "$report_dir/"

    log_info "Cleaning up remote report files on $server..."
    ssh -n "$remote_user@$server" "sudo rm -f /tmp/pre-results.xml /tmp/pre-report.html /tmp/post-results.xml /tmp/post-report.html"
}

main() {
    # Main function to orchestrate the security baseline application process
    log_info "Applying security baselines..."
    local server_list_file=""
    local remote_user=""
    
    while getopts "f:u:h" opt; do
        case $opt in
            f) server_list_file="$OPTARG" ;;
            u) remote_user="$OPTARG" ;;
            h) print_usage; exit 0 ;;
            \?) 
                log_error "Invalid option: -$OPTARG"
                print_usage
                exit 1
                ;;
            :) 
                log_error "Option -$OPTARG requires an argument."
                print_usage
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$server_list_file" || -z "$remote_user" ]]; then
        log_error "Both server list file and username are required."
        print_usage
        exit 1
    fi
    
    if [[ ! -f "$server_list_file" ]]; then
        log_error "Server list file '$server_list_file' does not exist."
        exit 1
    fi
    
    declare -a servers=()
    while IFS= read -r line; do
       if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        servers+=("$line")
    done < "$server_list_file"
    
    if [[ ${#servers[@]} -eq 0 ]]; then
        log_error "No valid servers found in the server list file."
        exit 1
    fi
    
    log_info "Found ${#servers[@]} servers to apply security baselines."
    
    for server in "${servers[@]}"; do
        check_server "$server" "$remote_user" || continue
        log_info "Applying security baselines to server: $server"
        harden_server "$server" "$remote_user"
    done
    
    log_info "Security baselines applied successfully. Check the ./reports/ directory."
}
# Set up a trap to ensure cleanup is called on script exit, interrupt, or termination
trap cleanup EXIT INT TERM
log_info "Script started at $(date)"
main "$@"