#!/usr/bin/env bash
# Title             :   ssh_run.sh
# Description       :   High-reliability parallel executor for remote operations. It validates
#                       host reachability, confirms privileged access, and then streams and runs
#                       a user-supplied payload script across multiple systems in a controlled,
#                       fully logged, fault-tolerant workflow.
# Author            :   George Vaideanu
# E-Mail            :   george@vaideanu.ro
# Creation Date     :   24-July-2023
# Latest Update     :   14-November-2025
# Usage             :   ./ssh_run.sh INVENTORY [ PAYLOAD ]
#
# Summary:
#   Automates large-scale remote execution driven by an inventory file.
#
#   The script:
#     • Performs PING checks to validate host reachability
#     • Verifies SSH access and passwordless sudo capability
#     • Streams and executes an optional payload on each target via:
#           cat payload_file | ssh user@host "sudo su -"
#     • Runs operations in parallel using the MAX_CONCURRENCY variable
#           Higher values increase speed; lower values reduce load on the jump host
#     • Executes the payload exactly “as is” under the target system’s default shell
#           No interpreter enforcement unless the payload explicitly enforces it (see payload_template for details)
#
#   Built for consistent, repeatable, parallel operations across mixed environments.
#
# Requirements:
#   • Inventory files must start with "inventory_*"
#         Ensures predictable workflows and prevents accidental misuse
#   • Payload files must start with "payload_*"
#         Guarantees only explicit, user-approved code is executed remotely
#   • SSH key-based authentication must be configured for the target environments
#   • The target user must be allowed to run “sudo su -” without a password
#
# Logging:
#   Each run creates a unique log directory:
#       log_ssh_run/<YYMMDD>_<PID>_<INVENTORY|PAYLOAD_NAME>
#   Contains both session-wide logs and per-host logs for full traceability.
#
# For extended documentation, examples and internals, refer to README.md
# ====================================================================================================

# Ensure the script is executed under bash with minimum required version.
ensure_bash() {
    MIN_MAJOR=4

    # prevent recursion
    [ -n "${ENSURE_BASH_DONE:-}" ] && return 0

    # Already in bash?
    if [ -n "${BASH_VERSINFO[0]:-}" ]; then
        [ "${BASH_VERSINFO[0]}" -lt "$MIN_MAJOR" ] &&
            { printf 'ERROR: bash >= %s required (current: %s)\n' "$MIN_MAJOR" "${BASH_VERSINFO[0]}" >&2; exit 2; }
        export ENSURE_BASH_DONE=1
        return 0
    fi

    # Not in bash → find one
    for C in \
		"$(command -v bash 2>/dev/null)" \
		/opt/freeware/bin/bash \
		/usr/bin/bash \
		/bin/bash; do
			[ -x "$C" ] || continue
			V="$("$C" -c 'echo ${BASH_VERSINFO[0]:-0}' 2>/dev/null || echo 0)"
			[ "$V" -ge "$MIN_MAJOR" ] || continue

			export ENSURE_BASH_DONE=1

			# file mode vs stdin mode
			if [ -n "${0:-}" ] && [ -f "$0" ]; then
				exec "$C" --noprofile --norc "$0" "$@"
			else
				exec "$C" --noprofile --norc -s -- "$@"
			fi
    done

    printf 'ERROR: bash >= %s not found.\n' "$MIN_MAJOR" >&2
    exit 2
}

ensure_bash "$@"

set -uo pipefail

################################
# Variables and script options #
################################

# Initialize global variables, detect mode (inventory/payload),
# set logging paths, pick target SSH user, configure per-OS settings.
set_variables() {

	# Positional arguments
	INVENTORY_FILE_ORIG="${1:-}"
	PAYLOAD_FILE="${2:-}"

	# Log dir set-up
	LOG_DIR_BASE="log_$(basename "${0%.*}")"
	LOG_DIR_DATE="$(date +%y%m%d)"
	LOG_DIR_RUN_ID="$$"

	# set BASE_NAME to payload or inventory name if payload not provided
	if [[ -n "$PAYLOAD_FILE" ]]; then
		BASE_NAME="$(basename "${PAYLOAD_FILE%.*}")"
	else
		BASE_NAME="$(basename "${INVENTORY_FILE_ORIG%.*}")"
	fi

	# Handle FAILED retry cleanly
	if [[ "$BASE_NAME" == *FAILED* ]]; then
		BASE_NAME="${BASE_NAME%%_FAILED*}" # strip trailing _FAILED or FAILED
	fi

	LOG_DIR_NAME="${LOG_DIR_DATE}_${LOG_DIR_RUN_ID}_${BASE_NAME}"
	LOG_DIR_RELATIVE_PATH="${LOG_DIR_BASE}/${LOG_DIR_NAME}"

	# Log files
	if [[ -z "$PAYLOAD_FILE" ]]; then
		LOG_FILE="${LOG_DIR_RELATIVE_PATH}/no_payload.txt"
	else
		LOG_FILE="${LOG_DIR_RELATIVE_PATH}/${BASE_NAME}_ALL.txt"
	fi

	# Always define FAILED_HOSTS_FILE in a consistent way
	FAILED_HOSTS_FILE="${LOG_DIR_RELATIVE_PATH}/${BASE_NAME}_FAILED.txt"

	# Host / user detection
	LOCAL_JH="$(hostname | cut -d. -f1 | tr '[:upper:]' '[:lower:]')"
	case "$LOCAL_JH" in
	lab*|mgmt*)
		JUMPHOST="$LOCAL_JH"
		USER_TO_RUN_AS="opsuser"
		TARGET_SSH_USER="root"
		;;
	prod*)
		JUMPHOST="$LOCAL_JH"
		USER_TO_RUN_AS="root"
		TARGET_SSH_USER="root"
		;;
	*)
		JUMPHOST="UNKNOWN"
		USER_TO_RUN_AS="UNKNOWN"
		TARGET_SSH_USER="UNKNOWN"
		;;
	esac

	# hosts to be skipped
	SKIP_HOSTS=(
		"testnode01"
		"legacy-backup02"
	)

	# SSH command
	SSH=(ssh -q
		-o BatchMode=yes
		-o UserKnownHostsFile=/dev/null
		-o PasswordAuthentication=no
		-o StrictHostKeyChecking=no
		-o ConnectTimeout=3
		-l "$TARGET_SSH_USER")

	# Misc
	BASH_PATH="$(command -v bash)"
	START_TIME="$(date +%s)"
	JUMPHOST_OS="$(uname)"
	MAX_CONCURRENCY=${MAX_CONCURRENCY:-20}

	case "$JUMPHOST_OS" in
	AIX)
		USE_SLEEP="yes"
		RATE_LIMITING="1"
		SLEEP="sleep"
		export PATH="/opt/freeware/bin:${PATH}"
		;;
	Linux)
		USE_SLEEP="yes"
		RATE_LIMITING="500000"
		SLEEP="usleep"
		;;
	*)
		echo "Error: Unknown OS type ($JUMPHOST_OS)"
		exit 1
		;;
	esac
}

###########################
# Output format functions #
###########################

# Print a long visual separator line using a repeated character.
sep() {
	for i in $(seq 118); do
		printf "${1}"
	done
	echo
}

# Print a shorter section separator line using a repeated character.
s_sep() {
	for i in $(seq 50); do
		printf "${1}"
	done
	echo
}

# Print several blank lines to visually separate output sections.
space_sep() {
	for ((i = 1; i < 6; i++)); do
		echo
	done
}

# Pretty-format a single PING/SSH/SUDO test result line.
printf_test_output() {
	SYSTEM_FQDN="${1:-}"
	OPERATION_STATUS="${2:-}"
	RETURN_CODE="${3:-}"
	printf "%-35s %-7s %-10s\n" "$SYSTEM_FQDN" "$OPERATION_STATUS" "$RETURN_CODE"
}

# Display usage information for the script arguments.
usage() {
	cat <<-EOF
		Usage: $(basename "$0") INVENTORY [ PAYLOAD ]

		ARGS:
			INVENTORY               -   Inventory file consisting of targeted systems, 1 system / line
			PAYLOAD    (optional)   -   Script file which will get executed on targeted systems

		Description: 
			- Each run creates a new log dir under log_ssh_run main dir
			- If PAYLOAD not specified, will perform PING and SSH test on each host within INVENTORY, storing run log in log dir
			- If PAYLOAD specified, will run it on each host, storing logs under log dir

	EOF
}

# Notify user if a FAILED hosts file was created.
print_failed_hosts_file() {
	if [[ -r "$FAILED_HOSTS_FILE" ]]; then
		echo "Failed hosts present: \"$FAILED_HOSTS_FILE\" created"
	fi
}

#################
# Sanity checks #
#################

# Validate the presence of required system binaries on the jumphost.
sanity_check_binaries() {

	[[ "$JUMPHOST_OS" == "Linux" ]] && REQUIRED=("perl" "tee" "id" "screen" "usleep" "mktemp" "awk")
	[[ "$JUMPHOST_OS" == "AIX" ]] && REQUIRED=("perl" "tee" "id" "screen" "mktemp" "awk")

	MISSING=()
	for BINARIES in "${REQUIRED[@]}"; do
		if ! type "$BINARIES" >/dev/null 2>&1; then
			MISSING+=("$BINARIES")
		fi
	done

	if ((${#MISSING[@]})); then
		printf "\n%-s\n\t%-s" "[ERROR] :" "- One or more required binaries not found on system: "
		for BINARY in "${MISSING[@]}"; do printf "%-s" "\"$BINARY\" "; done
		printf "\n\t%-s\n\n" "- Install them and retry the script."
		exit 2
	fi
}

# Ensure correct user context; enforce sudo impersonation if needed.
sanity_check_user() {
	if [[ $(whoami) != "$USER_TO_RUN_AS" ]]; then
		if [[ $(id -u) -eq 0 ]]; then
			if ! [[ $(id "$USER_TO_RUN_AS" 2>/dev/null) ]]; then
				echo
				echo "[ERROR] :  User $USER_TO_RUN_AS doesn't exists on system! Check \$USER_TO_RUN_AS"
				echo
				exit 2
			else
				SSH=(sudo -u "$USER_TO_RUN_AS" "${SSH[@]}")
			fi
		else
			echo
			echo "[ERROR] :  Script configured to be executed with $USER_TO_RUN_AS and you are $(whoami) (or use root which will impersonate \$USER_TO_RUN_AS)"
			echo
			exit 2
		fi
	else
		if ! [[ $(id "$USER_TO_RUN_AS" 2>/dev/null) ]]; then
			echo
			echo "[ERROR] :  User $USER_TO_RUN_AS doesn't exists on system! Check \$USER_TO_RUN_AS"
			echo
			exit 2
		fi
	fi
}

# Verify script is executed on a recognized, allowed jumphost.
sanity_check_jumphost() {
	if [[ -z "$JUMPHOST" || "$JUMPHOST" == "UNKNOWN" ]]; then
		echo
		echo "[ERROR] : Unauthorized or unidentified host '$(hostname -s 2>/dev/null || echo unknown)'. Exiting."
		echo
		exit 2
	fi
}

# Validate sleep/usleep settings used for rate-limiting concurrency.
sanity_check_sleep() {
	if [[ -n "$USE_SLEEP" ]]; then
		if [[ ! "$SLEEP" =~ ^(sleep|usleep)$ || ! "$RATE_LIMITING" =~ ^[0-9]+$ ]]; then
			echo
			echo "[ERROR] : USE_SLEEP is set but SLEEP or RATE_LIMITING is incorrectly defined, check VARs"
			echo
			exit 2
		fi
	fi
}

#############
# Utilities #
#############

# Remove temporary files, directories, and close file descriptors on exit.
cleanup() {
	[[ -n "${PING_OK_FL:-}" && -f "${PING_OK_FL:-}" ]] && rm -f -- "${PING_OK_FL}"
	[[ -n "${PING_FAIL_FL:-}" && -f "${PING_FAIL_FL:-}" ]] && rm -f -- "${PING_FAIL_FL}"
	[[ -n "${SUDO_OK_FL:-}" && -f "${SUDO_OK_FL:-}" ]] && rm -f -- "${SUDO_OK_FL}"
	[[ -n "${SUDO_FAIL_FL:-}" && -f "${SUDO_FAIL_FL:-}" ]] && rm -f -- "${SUDO_FAIL_FL}"
	[[ -n "${INVENTORY_FILE:-}" && -f "${INVENTORY_FILE}" ]] && rm -f -- "${INVENTORY_FILE}"
	[[ -n "${RUN_TMPDIR:-}" && -d "${RUN_TMPDIR}" ]] && rm -rf -- "${RUN_TMPDIR}"

	# best-effort close of the live stdout FD if it was opened
	if [[ -n "${LIVE_STDOUT:-}" ]]; then
		exec {LIVE_STDOUT}>&- 2>/dev/null || true
	fi
}

trap 'cleanup' EXIT

# Concurrency limiter: wait until active background jobs drop below threshold.
wait_for_slot() {
	local running
	while :; do
		running=$(jobs -p | wc -l)
		((running < MAX_CONCURRENCY)) && break
		"${SLEEP}" "${RATE_LIMITING}"
	done
}

# we need to identify later in script if target hostname is VIOS or not
is_vios() {
	local host="${1,,}"
	[[ "$host" =~ ^vios[0-9]+$ ]]
}

###############
# File checks #
###############

# Validate and sanitize the inventory file; create a temp copy safe for parallel runs.
file_check_inventory() {
	if [[ -z "$INVENTORY_FILE_ORIG" ]]; then
		echo
		echo "[ERROR] : INVENTORY file not specified"
		echo
		usage
		exit 2
	elif ! [[ "$(basename "$INVENTORY_FILE_ORIG")" =~ ^inventory_ ]]; then
		echo
		echo "[ERROR] : INVENTORY file must begin with \"inventory_\" prefix"
		echo
		exit 2
	elif [[ ! -r "$INVENTORY_FILE_ORIG" ]]; then
		echo
		echo "[ERROR] : The INVENTORY file: $INVENTORY_FILE_ORIG must be a valid and readable file containing hosts."
		echo
		exit 2
	elif [[ $(wc -l <"$INVENTORY_FILE_ORIG") -lt 1 ]]; then
		echo
		echo "[ERROR] : The INVENTORY file: $INVENTORY_FILE_ORIG seems to be emtpy."
		echo
		exit 2
	fi

	# inventory file can be used by multiple script forks
	INVENTORY_FILE="$(mktemp -t $(basename ${INVENTORY_FILE_ORIG}).XXXXX)"
	cp -- $INVENTORY_FILE_ORIG $INVENTORY_FILE # we copy the orig inventory file to unique one , this covers concurent script runs

	# temp normalization file (AIX needs this)
	local TMP="$(mktemp -t invtmp.XXXXXX)"

	# remove empty lines, whitespace, and CR/TAB
	sed '/^[[:space:]]*$/d' "$INVENTORY_FILE" |
		tr -d '\r\t ' \
			>"$TMP"
	mv "$TMP" "$INVENTORY_FILE"

	# convert to lowercase
	TMP="$(mktemp -t invtmp.XXXXXX)"
	tr '[:upper:]' '[:lower:]' <"$INVENTORY_FILE" >"$TMP"
	mv "$TMP" "$INVENTORY_FILE"

	# illegal characters check
	if grep -q "[^a-zA-Z0-9_-]" "$INVENTORY_FILE"; then
		echo
		echo "[ERROR] : Illegal characters found in ${INVENTORY_FILE}, accepted is only [a-zA-Z0-9_-]"
		echo
		exit 2
	fi
}

# Validate payload script name and readability if provided.
file_check_payload() {
	if [[ -n "$PAYLOAD_FILE" ]]; then
		if ! [[ "$(basename "$PAYLOAD_FILE")" =~ ^payload_ ]]; then
			echo
			echo "[ERROR] : PAYLOAD file must begin with \"payload_\" prefix"
			echo
			exit 2
		elif ! [[ -r "${PAYLOAD_FILE}" ]]; then
			echo
			echo "[ERROR] : File \"${PAYLOAD_FILE}\" does not exist or is not readable."
			echo
			exit 2
		fi
	fi
}

# Create the log directory for the current run.
log_dir_create() {
	if ! mkdir -p "$LOG_DIR_RELATIVE_PATH" 2>/dev/null; then
		echo
		echo "[ERROR] : Failed to create \"$LOG_DIR_RELATIVE_PATH\" . Exiting script"
		echo
		exit 2
	fi
}

################
# Script start #
################

# Re-exec the script inside a screen session, then enable log + terminal teeing.
start_screen_and_log() {
	# Check if the script is not running inside a screen session
	if [[ -z "${STY:-}" ]]; then

		# Start a new screen session with the script
		screen -S "ssh_run_$$" "$BASH_PATH" "$0" "$@"

		# Exit to prevent the script from running multiple times
		exit 0
	fi

	log_dir_create # we create the log dir under screen, so will not get created twice

	# Write everything to screen and log file
	exec > >(tee -a "${LOG_FILE}") 2>&1

	echo "$(s_sep \#) Starting script $(s_sep \#)"
	echo

	# Inform on OS type as well
	echo "JUMP HOST OS TYPE: $JUMPHOST_OS"
	echo
}

# Parallel PING test: resolve hosts via /etc/hosts or DNS and classify PASS/FAIL.
ping_test() {

	PING_OK_FL=$(mktemp) PING_FAIL_FL=$(mktemp)
	local RC REASON SYSTEM FQDN LAST_FQDN PING_SUCCESS
	local -a PIDS_PING=() FQDN_LIST=()
	PING_OK=() PING_FAIL=()

	TOTAL_HOSTS="$(wc -l <"${INVENTORY_FILE}")"

	sep "="
	echo "PING test on ${TOTAL_HOSTS} host(s)"
	sep "="
	echo

	while IFS= read -r HOST || [[ -n "$HOST" ]]; do
		[[ -z "$HOST" ]] && continue

		# Skip hosts
		for HOST_SKIP in "${SKIP_HOSTS[@]}"; do
			if [[ "$HOST" == "$HOST_SKIP" ]]; then
				printf_test_output "$HOST" "SKIP" "Host intentionally excluded"
				continue 2
			fi
		done

		wait_for_slot

		{

			SYSTEM="${HOST,,}"
			PING_SUCCESS=0

			# Define suffix list based on host pattern
			case "${SYSTEM}" in
			app*|srv*)
				FQDN_LIST=(".example.net" ".corp.example.net")
				;;
			db*|vios*)
				FQDN_LIST=(".example.net" ".mgmt.example.net")
				;;
			*)
				FQDN_LIST=(".example.net")
				;;
			esac

			# Check /etc/hosts first (exact alias match, ignore comments)
			if awk -v h="${SYSTEM}" '
							$0 !~ /^[[:space:]]*#/ && NF >= 2 {
								for (i=2; i<=NF; i++) if (tolower($i)==h) { exit 0 }
							}
							END{ exit 1 }
						' /etc/hosts; then
				if ping -c3 -w5 "${SYSTEM}" >/dev/null 2>&1; then
					printf_test_output "${SYSTEM}" "PASS"
					echo "${SYSTEM}" >>"${PING_OK_FL}"
					exit 0
				else
					RC="$?"
					case "$RC" in
					1) REASON="unreachable" ;;
					2) REASON="unknown host" ;;
					*) REASON="timeout/error" ;;
					esac
					printf_test_output "${SYSTEM}" "FAIL" "RC: $RC ($REASON)"
					echo "${SYSTEM}" >>"${PING_FAIL_FL}"
					exit 0
				fi
			fi

			# If not found in /etc/hosts, try DNS FQDNs
			printf_test_output "${SYSTEM}" "WARN" "RC: not in hosts, switching to DNS"
			for FQDN_SUFFIX in "${FQDN_LIST[@]}"; do
				FQDN="${SYSTEM}${FQDN_SUFFIX}"
				if ping -c3 -w5 "${FQDN}" >/dev/null 2>&1; then
					printf_test_output "${FQDN}" "PASS"
					echo "${FQDN}" >>"${PING_OK_FL}"
					PING_SUCCESS=1
					break
				else
					RC="$?"
					case "$RC" in
					1) REASON="unreachable" ;;
					2) REASON="unknown host" ;;
					*) REASON="timeout/error" ;;
					esac
					printf_test_output "${FQDN}" "WARN" "RC: $RC ($REASON)"
				fi
			done

			if [[ "$PING_SUCCESS" -eq 0 ]]; then
				LAST_FQDN="${SYSTEM}${FQDN_LIST[-1]}"
				printf_test_output "${LAST_FQDN}" "FAIL" "RC: $RC ($REASON)"
				echo "${LAST_FQDN}" >>"${PING_FAIL_FL}"
			fi
		} &

		PIDS_PING+=("$!")
	done <"${INVENTORY_FILE}"

	# Wait for PIDs to end before moving on
	for PID in "${PIDS_PING[@]}"; do
		wait "$PID" 2>/dev/null
	done

	# Gather results
	readarray -t PING_OK < <(grep -v "^$" "$PING_OK_FL" 2>/dev/null)
	readarray -t PING_FAIL < <(grep -v "^$" "$PING_FAIL_FL" 2>/dev/null)

	echo
	echo "PING test completed -> | HOSTS: ${TOTAL_HOSTS} | PASS: ${#PING_OK[@]} | FAIL: ${#PING_FAIL[@]} |"
	sep "="

	space_sep
}

# Parallel SSH + SUDO validation: detect proper sudo command and record results.
sudo_test() {

	local RC SSH_HOST CLIENT_SUDO_COMMAND
	local -a PIDS_SUDO=()
	SUDO_OK=() SUDO_FAIL=()

	SUDO_OK_FL=$(mktemp) SUDO_FAIL_FL=$(mktemp)

	if [[ ${#PING_OK[@]} -eq 0 ]]; then
		return 2
	fi

	sep "="
	echo "SUDO test on ${#PING_OK[@]} host(s)"
	sep "="
	echo

	for SSH_HOST in "${PING_OK[@]}"; do

		# Determine sudo command (VIOS vs LPAR/VM)
		if is_vios "$SSH_HOST"; then
			CLIENT_SUDO_COMMAND="/usr/ios/cli/ioscli oem_setup_env"
		else
			CLIENT_SUDO_COMMAND="sudo su -"
		fi

		{

			if "${SSH[@]}" "$SSH_HOST" "echo cd | $CLIENT_SUDO_COMMAND >/dev/null 2>&1"; then
				printf_test_output "$SSH_HOST" "PASS"
				echo "$SSH_HOST" >>"$SUDO_OK_FL"
			else
				RC="$?"
				printf_test_output "${SSH_HOST}" "FAIL" "RC: $RC"
				echo "$SSH_HOST" >>"$SUDO_FAIL_FL"
			fi

		} &

		PIDS_SUDO+=($!)
		[[ -n "${USE_SLEEP:-}" ]] && "$SLEEP" "$RATE_LIMITING" # limit outgoing SSH connection

	done

	# Wait for PIDs to end before moving on
	for PID_SUDO in "${PIDS_SUDO[@]}"; do
		wait "$PID_SUDO" 2>/dev/null || true
	done

	# reading back arrays from temp files
	readarray -t SUDO_OK < <(grep -v "^$" "$SUDO_OK_FL")
	readarray -t SUDO_FAIL < <(grep -v "^$" "$SUDO_FAIL_FL")

	echo
	echo "SUDO test completed -> | HOSTS: ${#PING_OK[@]} | PASS: ${#SUDO_OK[@]} | FAIL: ${#SUDO_FAIL[@]} |"
	sep "="

	space_sep
}

# Print summarized PING/SUDO failures and build FAILED hosts list.
display_ping_sudo_results() {

	HOST_CLEANUP_NW_CMD='s/\(\.example\.net\)//'
	STOP_TIME="$(date +%s)"

	if [[ ${#PING_FAIL[@]} -ge 1 ]] || [[ ${#SUDO_FAIL[@]} -ge 1 ]]; then
		sep "="
		echo "PING/SUDO SUMMARY"
		sep "="
		if [[ ${#PING_FAIL[@]} -ge 1 ]]; then
			echo
			sep "-"
			echo "PING failed on ${#PING_FAIL[@]} host(s):"
			echo

			for PING_FAIL_HOST in "${PING_FAIL[@]}"; do
				echo "- $PING_FAIL_HOST"
				echo "${PING_FAIL_HOST%%.*}" | sed "$HOST_CLEANUP_NW_CMD" >>"$FAILED_HOSTS_FILE"
			done
			sep "-"
			echo
		fi
	fi

	if [[ "${#SUDO_FAIL[@]}" -ge 1 ]]; then
		echo
		sep "-"
		echo "SUDO failed on ${#SUDO_FAIL[@]} host(s):"
		echo
		for SUDO_FAIL_HOST in "${SUDO_FAIL[@]}"; do
			echo "- $SUDO_FAIL_HOST"
			echo "${SUDO_FAIL_HOST%%.*}" | sed "$HOST_CLEANUP_NW_CMD" >>"$FAILED_HOSTS_FILE"
		done
		sep "-"
		echo
	fi

	cat <<-EOF

		--------------------| SUMMARY |--------------------

		TOTAL HOSTS:        ${TOTAL_HOSTS}
		PING FAIL:          ${#PING_FAIL[@]}
		SUDO FAIL:          ${#SUDO_FAIL[@]}
		TOTAL FAIL:         $((${#PING_FAIL[@]} + ${#SUDO_FAIL[@]}))
		ACCESSIBLE:         ${#SUDO_OK[@]}
		EST RUN TIME:       $((${STOP_TIME} - ${START_TIME}))s

		--------------------| SUMMARY |--------------------

	EOF

	if [[ "${#SUDO_OK[@]}" -eq 0 || ${#PING_OK[@]} -eq 0 ]]; then
		echo "No hosts accessible, nothing to go on! Exiting!"
		echo
		sep "="
		echo
		echo "Main log directory: \"$LOG_DIR_RELATIVE_PATH\""
		print_failed_hosts_file
		echo
		sep "="
		echo
		echo
		echo "$(s_sep \#) Script finalized $(s_sep \#)"
		sleep 1
		exit 2
	elif [[ ${#PING_FAIL[@]} -eq 0 ]] && [[ ${#SUDO_FAIL[@]} -eq 0 ]]; then
		sep "="
		echo "PING/SUDO SUMMARY: ALL TESTS PASSED, NICE!"
		sep "="
	fi

	echo
	echo "Main log directory: \"$LOG_DIR_RELATIVE_PATH\""
}

# Exit early if no payload is provided; still display test summaries.
no_payload_file_stop_script() {
	# If no payload, exit
	if [[ -z ${PAYLOAD_FILE} ]]; then
		display_ping_sudo_results
		print_failed_hosts_file
		echo
		echo "PAYLOAD script not specified, exiting script"
		echo
		echo "$(s_sep \#) Script finalized $(s_sep \#)"
		echo
		sleep 1

		exit 0
	fi
}

# Run payload on all SUDO_OK hosts in parallel; generate per-host and global logs.
execute_payload_and_log_everything() {

	if [[ ${#SUDO_OK[@]} -gt 0 ]]; then
		sep "="
		echo "Running $(basename "${PAYLOAD_FILE}") on ${#SUDO_OK[@]} host(s)"
		sep "="
		echo
	fi
	
	local -a PIDS_SSH=()

	EVI_LOG_FILE="$LOG_DIR_RELATIVE_PATH/$(basename "${PAYLOAD_FILE}")_EVI"

	# create a temp dir for per-host logs (prevents concurrent writes)
	RUN_TMPDIR="$(mktemp -d -t ssh_run.XXXXXX)" || {
		echo "[ERROR] mktemp failed" >&2
		return 2
	}

	# remember current terminal stdout so background jobs can write to it
	exec {LIVE_STDOUT}>&1

	# execute payload and store logs accordingly
	for SSH_HOST_OK in "${SUDO_OK[@]}"; do

		# SUDO CMD - LPAR vs VIOS
		if is_vios "$SSH_HOST_OK"; then
			CLIENT_SUDO_COMMAND="/usr/ios/cli/ioscli oem_setup_env"
		else
			CLIENT_SUDO_COMMAND="sudo su -"
		fi

		{ # backgrounded job
			host_short="${SSH_HOST_OK%%.*}"
			tmp_buf="$RUN_TMPDIR/${host_short}.buf"

			if SSH_CMD="$(
				{ cat "$PAYLOAD_FILE" | "${SSH[@]}" "$SSH_HOST_OK" "$CLIENT_SUDO_COMMAND"; } 2>&1
			)"; then
				{
					sep "-"
					echo "Executing payload on ${SSH_HOST_OK}"
					echo
					echo "$SSH_CMD" |
						grep -v -i -e "terminal" -e "mail" -e "logout" |
						sed '/^$/d'
					echo
					echo "PASS: Payload executed successfully on ${SSH_HOST_OK}"
					sep "-"
					echo
				} >"$tmp_buf"

				# atomic flush (no interleaving, live on terminal)
				cat "$tmp_buf" |
					tee -a "${EVI_LOG_FILE}.txt" |
					tee -a "${EVI_LOG_FILE}_${host_short}.txt" >&"${LIVE_STDOUT}"

				{
					echo
					sep "="
					echo
				} >>"${EVI_LOG_FILE}.txt"
			else
				SSH_RC="$?"
				{
					sep "-"
					echo "Executing payload on ${SSH_HOST_OK}"
					echo
					echo "$SSH_CMD" |
						grep -v -i -e "terminal" -e "mail" -e "logout" |
						sed '/^$/d'
					echo
					echo "FAIL: Payload failed on ${SSH_HOST_OK} RC: $SSH_RC"
					sep "-"
					echo
				} >"$tmp_buf"

				cat "$tmp_buf" |
					tee -a "${EVI_LOG_FILE}.err" |
					tee -a "${EVI_LOG_FILE}_${host_short}.err" >&"${LIVE_STDOUT}"

				{
					echo
					sep "="
					echo
				} >>"${EVI_LOG_FILE}.err"
			fi

			rm -f -- "$tmp_buf"
		} &

		PIDS_SSH+=("$!")
		[[ "$USE_SLEEP" ]] && "$SLEEP" "$RATE_LIMITING" # throttle SSH launches
	done

	# Wait for all background jobs to complete
	for PID_SSH in "${PIDS_SSH[@]}"; do
		wait "$PID_SSH"
	done

	exec {LIVE_STDOUT}>&-

	sep "="
	space_sep

	display_ping_sudo_results
}

# Detect empty/invalid per-host logs and append them to FAILED list.
check_empty_log_file() {
	# Check for empty or near-empty log files (<2 bytes)
	HOST_CLEANUP_PAYLOAD_FILE_CMD_AWK=(awk -F "_" '{print $NF}')
	HOST_CLEANUP_PAYLOAD_FILE_CMD_SED=(sed 's/\(\.txt\|\.err\)//')

	FAILED_HOSTS="$(
		find "$LOG_DIR_RELATIVE_PATH" -type f 2>/dev/null | while read -r f; do
			# Portable size check (works on AIX and Linux)
			size=$(wc -c <"$f" 2>/dev/null || echo 0)
			[ "${size:-0}" -lt 2 ] && basename "$f"
		done | "${HOST_CLEANUP_PAYLOAD_FILE_CMD_AWK[@]}" | "${HOST_CLEANUP_PAYLOAD_FILE_CMD_SED[@]}"
	)"

	if [[ -n "$FAILED_HOSTS" ]]; then
		for FAILED_HOST in $FAILED_HOSTS; do
			echo "$FAILED_HOST" >>"$FAILED_HOSTS_FILE"
		done
	fi

	print_failed_hosts_file
	echo
	echo "$(s_sep \#) Script finalized $(s_sep \#)"
	echo
	sleep 1
}

# Orchestrate full script flow: initialization → tests → payload → cleanup.
main() {
	set_variables "$@"
	sanity_check_binaries
	sanity_check_user
	sanity_check_jumphost
	sanity_check_sleep
	file_check_inventory
	file_check_payload
	start_screen_and_log "$@"
	ping_test
	sudo_test
	no_payload_file_stop_script
	execute_payload_and_log_everything
	check_empty_log_file
}

# Catch termination signals, run cleanup, and terminate background jobs safely.
trap 'cleanup; trap - INT TERM; echo "[INFO] Caught termination signal, killing process group $$"; kill -TERM -- -$$ 2>/dev/null' INT TERM

main "$@"
