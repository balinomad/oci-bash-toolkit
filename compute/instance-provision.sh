#!/usr/bin/env bash

# instance-provision.sh - Provision an OCI compute instance with retry and AD cycling.
#
# Reads an instance launch spec JSON template, substitutes {{AD_NUMBER}} for each
# configured availability domain, then retries across ADs in a loop until an instance
# is created or a terminal condition is reached (auth failure, config error, too many
# errors, or max cycles exceeded).
#
# On success the provisioned instance JSON is written to stdout (or --output FILE).
# All log and progress output goes to stderr.
#
# Usage:
#   instance-provision.sh --spec FILE [OPTIONS]

# Bash version check
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../lib" && pwd)/bash-version-check.sh"

set -euo pipefail

# Set LOG_LEVEL before sourcing other scripts
# 0 = quiet  → only LOG_ERROR (and fatal) emit
# 1 = normal → LOG_INFO + LOG_ERROR  (default)
# 2 = verbose→ LOG_DEBUG + LOG_INFO + LOG_ERROR
declare LOG_LEVEL=1
export LOG_LEVEL

# Set OCI_READ_TIMEOUT before sourcing other scripts
declare OCI_READ_TIMEOUT=60
export OCI_READ_TIMEOUT

# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/../lib"

source "${LIB_DIR}/shell-utils.sh"
source "${LIB_DIR}/oci-helpers.sh"

# --- Operational Defaults ---
# These are not exposed as CLI flags; edit them to adjust provisioning behaviour.

readonly DEFAULT_AD_NUMBERS=(1 2 3)
readonly DEFAULT_MAX_CYCLES=5000
readonly DEFAULT_MAX_ERROR_CYCLES=3
readonly DEFAULT_BASE_BACKOFF=1
readonly DEFAULT_MAX_BACKOFF=300
readonly DEFAULT_MAX_BACKOFF_ATTEMPTS=9
readonly DEFAULT_DECORRELATED_JITTER=1
readonly DEFAULT_INTER_AD_MIN=1
readonly DEFAULT_INTER_AD_MAX=6

# --- Usage ---

usage() {
	cat <<-EOF
	Usage: $(basename "$0") [OPTIONS]

	Provision an OCI compute instance with retry across availability domains.
	Cycles through each configured AD until an instance is created or a terminal
	condition is reached (auth failure, config error, too many errors, max cycles).

	On success, the provisioned instance JSON is written to stdout unless --output
	is given. All log and progress output goes to stderr.

	Required:
	  -s, --spec    FILE     Instance launch spec JSON template.
	                         Use {{AD_NUMBER}} as a placeholder for the AD index.

	Optional:
	  -p, --profile PROFILE  OCI CLI profile (default: DEFAULT or \$OCI_PROFILE)
	  -c, --config  FILE     OCI config file (default: ~/.oci/config or \$OCI_CONFIG_FILE)
	  -o, --output  FILE     Write provisioned instance JSON to FILE instead of stdout
	  -t, --timeout SECS     OCI CLI read timeout in seconds; 0 = OCI CLI default
	      --dry-run          Render per-AD specs and print commands without making API calls
	  -q, --quiet            Suppress info-level output (errors always shown)
	  -v, --verbose          Enable debug-level output
	  -h, --help             Show this help message

	Environment variables:
	  OCI_PROFILE            Same as --profile
	  OCI_CONFIG_FILE        Same as --config
	EOF
	exit 0
}

# --- Script-specific Utilities ---

# Prefix with SCRIPT_DIR when given a bare filename (no path separator).
# Args: file
# Output: resolved path to stdout
prefix_with_script_dir() {
	local file="${1:-}"
	[[ "${file}" == */* ]] && printf '%s\n' "${file}" || printf '%s\n' "${SCRIPT_DIR}/${file}"
}

# --- Process Lock ---

# Acquire a process-lifetime exclusive lock using atomic mkdir.
# Detects and removes stale locks by checking whether the recorded PID is still live.
# Sets: LOCK_DIR (global)
# Exits via fatal if a live concurrent instance holds the lock.
acquire_process_lock() {
	local runtime_dir lockdir pid_file script_name
	script_name="${0##*/}"
	script_name="${script_name%.sh}"

	if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
		runtime_dir="${XDG_RUNTIME_DIR}"
	elif [[ -d "${HOME}/.local/state" ]]; then
		runtime_dir="${HOME}/.local/state"
	elif [[ -w "${HOME}" ]]; then
		runtime_dir="${HOME}/.cache"
	else
		runtime_dir="/tmp"
	fi

	mkdir -p "${runtime_dir}/oci-provision" \
		|| fatal "cannot create lock parent directory: ${runtime_dir}/oci-provision"

	lockdir="${runtime_dir}/oci-provision/${script_name}.lock"
	pid_file="${lockdir}/pid"

	if ! mkdir "${lockdir}" 2>/dev/null; then
		local existing_pid=""
		[[ ! -f "${pid_file}" ]] || existing_pid="$(<"${pid_file}")" 2>/dev/null || :

		if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
			fatal "another instance is already running (PID ${existing_pid}); lock: ${lockdir}"
		fi

		# Stale lock from a dead process — remove and retry once
		log_warn "removing stale process lock (PID ${existing_pid:-unknown}): ${lockdir}"
		rm -f -- "${pid_file}"
		rmdir "${lockdir}" 2>/dev/null \
			|| fatal "cannot remove stale lock directory: ${lockdir}"
		mkdir "${lockdir}" 2>/dev/null \
			|| fatal "cannot acquire process lock after stale removal: ${lockdir}"
	fi


	printf '%d\n' "$$" > "${pid_file}" \
		|| fatal "cannot write PID to lock file: ${pid_file}"
	LOCK_DIR="${lockdir}"
}

# Release the process lock. Safe to call when LOCK_DIR is unset.
# shellcheck disable=SC2329
release_process_lock() {
	[[ -n "${LOCK_DIR:-}" ]] || return 0
	rm -f -- "${LOCK_DIR}/pid" 2>/dev/null || :
	rmdir "${LOCK_DIR}" 2>/dev/null || :
	LOCK_DIR=""
}

# --- Provisioning Utilities ---

# Return a uniform random integer in [min, max] inclusive.
# Uses shuf when available; falls back to RANDOM-based sampling.
# Args: min max
# Output: integer to stdout
rand_in_range() {
	local min="${1:-0}"
	local max="${2:-0}"
	(( max > min )) || { printf '%d\n' "${min}"; return 0; }
	if command -v shuf >/dev/null 2>&1; then
		shuf -i "${min}-${max}" -n1
		return 0
	fi
	printf '%d\n' "$(( RANDOM % (max - min + 1) + min ))"
}

# Compute adaptive sleep duration using exponential backoff with decorrelated jitter.
# Args: attempts
# Globals: BASE_BACKOFF, MAX_BACKOFF, MAX_BACKOFF_ATTEMPTS, DECORRELATED_JITTER
# Output: sleep duration in seconds to stdout
compute_adaptive_sleep() {
	local attempts="${1:-0}"
	(( attempts >= 0 )) || attempts=0
	local exp base_exp jitter total
	exp=$(( attempts < MAX_BACKOFF_ATTEMPTS ? attempts : MAX_BACKOFF_ATTEMPTS ))
	base_exp=$(( BASE_BACKOFF * (1 << exp) ))
	jitter=$(rand_in_range 0 "${DECORRELATED_JITTER}")
	total=$(( base_exp + jitter ))
	(( total <= MAX_BACKOFF )) || total="${MAX_BACKOFF}"
	printf '%d\n' "${total}"
}

# Parse raw OCI CLI error text into NUL-separated fields:
# preamble, error_code, error_message, http_status.
# Handles OCI JSON error responses as well as plain-text and mixed output.
# Args: raw_error_string
# Output: NUL-delimited fields to stdout
process_output() {
	local output="${1:-}"
	[[ -n "${output}" ]] || { printf '%s\0\0\0\0' "MissingOutput"; return 0; }

	local preamble json_part error_code error_msg http_status
	preamble="${output}"
	json_part=""
	if [[ "${output}" == *'{'* ]]; then
		preamble="${output%%\{*}"
		json_part="{${output#*\{}"
	fi

	if printf '%s' "${json_part}" | jq -e . >/dev/null 2>&1; then
		error_code=$(printf '%s' "${json_part}" | jq -r '.code    // "Unknown"')
		error_msg=$(printf '%s'  "${json_part}" | jq -r '.message // "None"')
		http_status=$(printf '%s' "${json_part}" | jq -r '.status  // 500')
	else
		error_code="NonJsonResponse"
		error_msg="Raw: $(printf '%.150s' "$(printf '%s' "${output}" | tr -d '\n')")"
		http_status=500
	fi

	printf '%s\0%s\0%s\0%s\0' "${preamble}" "${error_code}" "${error_msg}" "${http_status}"
}

# Classify an OCI error into a dispatch token for the main loop.
# Tokens: EMPTY | TIMEOUT | AUTH | CONFIG | CAPACITY | THROTTLE | STATE | UNKNOWN
# Args: preamble code msg http_status
classify_error() {
	local preamble="${1:-}"
	local code="${2:-}"
	local msg="${3:+${3,,}}"
	local status="${4:-}"

	[[ "${preamble}" != "MissingOutput" ]]                                                || { printf 'EMPTY';    return 0; }
	[[ "${msg}" != *"timed out"* ]]                                                       || { printf 'TIMEOUT';  return 0; }
	[[ "${code}" != "NotAuthenticated" && "${status}" != 401 ]]                           || { printf 'AUTH';     return 0; }
	[[ ! "${code}" =~ ^(NotAuthorizedOrNotFound|InvalidParameter|LimitExceeded)$ ]]       || { printf 'CONFIG';   return 0; }
	[[ "${code}" != "IncorrectState" && "${status}" != 409 ]]                             || { printf 'STATE';    return 0; }
	[[ "${code}" != "InternalError" || ( "${msg}" != *out* && "${msg}" != *capacity* ) ]] || { printf 'CAPACITY'; return 0; }
	[[ "${status}" != 429 && "${code}" != "TooManyRequests" ]]                            || { printf 'THROTTLE'; return 0; }
	printf 'UNKNOWN'
}

# Log each entry in an AD detail array at debug level.
# Args: nameref name of the ad_log array
log_ad_details() {
	local -n _ad_log_ref="${1}"
	[[ ${#_ad_log_ref[@]} -gt 0 ]] || return 0
	local entry
	for entry in "${_ad_log_ref[@]}"; do
		log_debug "${entry}"
	done
}

# Attempt to provision a compute instance on the specified AD.
# Uses oci_capture_json so output is clean JSON on success and structured error on failure.
# Args: ad (positive integer)
# Globals: PROFILE, OCI_READ_TIMEOUT (via oci_capture_json), AD_CONFIGS
# Output: NUL-separated fields to stdout: token, duration_s, preamble, raw_error
attempt_provisioning() {
	local ad="${1:-0}"
	(( ad > 0 )) || fatal "invalid AD number passed to attempt_provisioning: '${ad}'"

	local start_ts duration err_msg="" output="" rc=0
	start_ts=$(date +%s)

	output=$(oci_capture_json err_msg "${PROFILE}" compute instance launch \
		--from-json "file://${AD_CONFIGS[$ad]}") || rc=$?
	duration=$(( $(date +%s) - start_ts ))

	if (( rc == 0 )); then
		printf '%s\0%d\0\0%s\0' "OK" "${duration}" "${output}"
		return 0
	fi

	local preamble error_code error_msg http_status error_token
	mapfile -d '' -t error_fields < <(process_output "${err_msg}")
	preamble="${error_fields[0]:-}"
	error_code="${error_fields[1]:-}"
	error_msg="${error_fields[2]:-}"
	http_status="${error_fields[3]:-}"
	error_token=$(classify_error "${preamble}" "${error_code}" "${error_msg}" "${http_status}")

	printf '%s\0%d\0%s\0%s\0' "${error_token}" "${duration}" "${preamble}" "${err_msg}"
}

# --- Parse Arguments ---

declare PROFILE="${OCI_PROFILE:-DEFAULT}"
declare CONFIG_FILE="${OCI_CONFIG_FILE:-${HOME}/.oci/config}"
declare SPEC=""
declare OUT=""
declare DRY_RUN=false

# Operational tuning — modify these to change provisioning behaviour.
declare -a AD_NUMBERS=("${DEFAULT_AD_NUMBERS[@]}")
declare MAX_CYCLES="${DEFAULT_MAX_CYCLES}"
declare MAX_ERROR_CYCLES="${DEFAULT_MAX_ERROR_CYCLES}"
declare BASE_BACKOFF="${DEFAULT_BASE_BACKOFF}"
declare MAX_BACKOFF="${DEFAULT_MAX_BACKOFF}"
declare MAX_BACKOFF_ATTEMPTS="${DEFAULT_MAX_BACKOFF_ATTEMPTS}"
declare DECORRELATED_JITTER="${DEFAULT_DECORRELATED_JITTER}"
declare INTER_AD_MIN="${DEFAULT_INTER_AD_MIN}"
declare INTER_AD_MAX="${DEFAULT_INTER_AD_MAX}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-s|--spec)
			SPEC="${2:-}"
			[[ -n "${SPEC}" ]] || fatal "--spec cannot be empty"
			shift 2
			;;
		-p|--profile)
			PROFILE="${2:-}"
			[[ -n "${PROFILE}" ]] || fatal "--profile cannot be empty"
			shift 2
			;;
		-c|--config)
			CONFIG_FILE="${2:-}"
			[[ -n "${CONFIG_FILE}" ]] || fatal "--config cannot be empty"
			shift 2
			;;
		-o|--output)
			OUT="${2:-}"
			[[ -n "${OUT}" ]] || fatal "--output cannot be empty"
			shift 2
			;;
		-t|--timeout)
			OCI_READ_TIMEOUT="${2:-}"
			[[ "${OCI_READ_TIMEOUT}" =~ ^[0-9]+$ ]] \
				|| fatal "--timeout must be a non-negative integer; got: '${OCI_READ_TIMEOUT}'"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-q|--quiet)
			LOG_LEVEL=0
			shift
			;;
		-v|--verbose)
			LOG_LEVEL=2
			shift
			;;
		-h|--help)
			usage
			;;
		*)
			fatal "unknown option: $1 (use --help for usage)"
			;;
	esac
done

# --- Validation ---

err_msg=""
require_commands err_msg jq oci sleep sed || fatal "${err_msg}" $?

[[ -n "${SPEC}" ]] || fatal "--spec is required"

SPEC=$(prefix_with_script_dir "${SPEC}")
[[ -f "${SPEC}" ]] || fatal "spec file not found: ${SPEC}"
jq -e . >/dev/null 2>&1 < "${SPEC}" || fatal "spec file contains invalid JSON: ${SPEC}"

[[ -f "${CONFIG_FILE}" ]] || fatal "OCI config file not found: ${CONFIG_FILE}"

if [[ -n "${OUT}" ]]; then
	out_dir="$(dirname -- "${OUT}")"
	[[ -d "${out_dir}" && -w "${out_dir}" ]] || fatal "output directory not writable: ${out_dir}"
fi

# AD_NUMBERS may only contain positive integers; this guards the sed substitution below.
for ad in "${AD_NUMBERS[@]}"; do
	[[ "${ad}" =~ ^[1-9][0-9]*$ ]] || fatal "AD_NUMBERS must contain positive integers; got: '${ad}'"
done

readonly MAX_ERRORS=$(( ${#AD_NUMBERS[@]} * MAX_ERROR_CYCLES ))

# --- State Initialisation ---

declare EXIT_CALLED=0
declare CYCLE=0
declare TOTAL_ERRORS=0
declare BACKOFF_ATTEMPTS=0
declare LOCK_DIR=""
declare -a ad_log=()
declare -A AD_CONFIGS=()

# --- Cleanup ---

# shellcheck disable=SC2329
on_exit() {
	local code="${1:-$?}"
	[[ "${EXIT_CALLED}" -eq 0 ]] || return 0
	EXIT_CALLED=1
	log_info "exiting: code=${code}, cycles=${CYCLE}, total_errors=${TOTAL_ERRORS}"
	local ad
	for ad in "${AD_NUMBERS[@]}"; do
		[[ -z "${AD_CONFIGS[${ad}]:-}" ]] || rm -f -- "${AD_CONFIGS[${ad}]}" 2>/dev/null || :
	done
	release_process_lock
}
trap 'on_exit 143' TERM
trap 'on_exit 130' INT
trap 'on_exit'     EXIT

# --- Process Lock ---

acquire_process_lock

# --- Per-AD Spec Rendering ---
# Substitute {{AD_NUMBER}} in the template for each configured AD and validate
# that the result is still well-formed JSON before any API call is made.

ad_config_tmp=""
for ad in "${AD_NUMBERS[@]}"; do
	ad_config_tmp=$(mktemp) || fatal "cannot create temp spec file for AD ${ad}"
	sed "s|{{AD_NUMBER}}|${ad}|g" "${SPEC}" > "${ad_config_tmp}"
	jq -e . >/dev/null 2>&1 < "${ad_config_tmp}" \
		|| fatal "rendered spec for AD ${ad} is not valid JSON; check {{AD_NUMBER}} substitution in: ${SPEC}"
	AD_CONFIGS[$ad]="${ad_config_tmp}"
done
unset ad ad_config_tmp

# --- Dry Run ---

if [[ "${DRY_RUN}" == "true" ]]; then
	log_info "dry run: no OCI API calls will be made"
	for ad in "${AD_NUMBERS[@]}"; do
		log_info "AD-${ad} command: oci compute instance launch --from-json file://${AD_CONFIGS[$ad]} --profile ${PROFILE} --output json"
		log_info "AD-${ad} rendered spec:"
		# Emit pretty-printed JSON directly to stderr for operator inspection.
		jq '.' "${AD_CONFIGS[$ad]}" >&2
	done
	exit 0
fi

# --- Startup ---

log_info "starting OCI instance provisioning"
log_info "profile:      ${PROFILE}"
log_info "spec:         ${SPEC}"
log_info "max cycles:   ${MAX_CYCLES}"
log_info "ADs:          ${AD_NUMBERS[*]}"
log_info "base backoff: ${BASE_BACKOFF}s, max: ${MAX_BACKOFF}s"
log_info "read timeout: ${OCI_READ_TIMEOUT}s (0 = OCI CLI default)"
[[ -z "${OUT}" ]] || log_info "output:       ${OUT}"

# --- Main Provisioning Loop ---

while (( CYCLE < MAX_CYCLES )); do
	CYCLE=$(( CYCLE + 1 ))
	cycle_log="cycle ${CYCLE}:"
	ad_log=()
	throttled=0
	cycle_errors=0

	for ad in "${AD_NUMBERS[@]}"; do
		mapfile -d '' -t result_fields < <(attempt_provisioning "${ad}")
		token="${result_fields[0]:-}"
		duration="${result_fields[1]:-0}"
		preamble="${result_fields[2]:-}"
		output="${result_fields[3]:-}"

		[[ "${ad}" == "${AD_NUMBERS[0]}" ]] || cycle_log+=','
		cycle_log+=" AD-${ad}"

		case "${token}" in
			CAPACITY)
				cycle_log+=" full"
				ad_log+=("AD-${ad} capacity error: ${output}")
				;;
			EMPTY)
				cycle_log+=" no result"
				TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
				cycle_errors=$(( cycle_errors + 1 ))
				;;
			TIMEOUT)
				cycle_log+=" timeout"
				TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
				ad_log+=("AD-${ad} timed out after ${duration}s: ${output}")
				;;
			THROTTLE)
				cycle_log+=" throttled"
				throttled=1
				ad_log+=("AD-${ad} throttled: ${output}")
				;;
			STATE)
				cycle_log+=" incorrect state"
				ad_log+=("AD-${ad} state error: ${output}")
				;;
			UNKNOWN)
				cycle_log+=" unknown error"
				TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
				cycle_errors=$(( cycle_errors + 1 ))
				ad_log+=("AD-${ad} unknown error: ${output}")
				;;
			OK)
				cycle_log+=" success (${duration}s)"
				log_info "${cycle_log}"
				log_info "instance provisioned in AD-${ad}"
				log_debug "instance JSON: ${output}"
				if [[ -n "${OUT}" ]]; then
					printf '%s\n' "${output}" > "${OUT}" \
						|| log_warn "instance provisioned but failed to write to: ${OUT}"
				else
					printf '%s\n' "${output}"
				fi
				exit 0
				;;
			CONFIG)
				cycle_log+=" config error (${duration}s)"
				log_error "${cycle_log}"
				log_error "AD-${ad}: config error — ${preamble}"
				log_debug "${output}"
				exit 1
				;;
			AUTH)
				cycle_log+=" auth error (${duration}s)"
				log_error "${cycle_log}"
				log_error "AD-${ad}: authentication error — ${preamble}"
				log_debug "${output}"
				exit 1
				;;
			*)
				cycle_log+=" unexpected token '${token}' (${duration}s)"
				log_error "${cycle_log}"
				log_error "AD-${ad}: unexpected error — ${preamble}"
				log_debug "${output}"
				exit 1
				;;
		esac

		# Append duration for non-terminal tokens (terminal cases exit above).
		cycle_log+=" (${duration}s)"

		if (( TOTAL_ERRORS >= MAX_ERRORS )); then
			log_error "${cycle_log}"
			log_ad_details ad_log
			log_error "too many errors (${TOTAL_ERRORS}/${MAX_ERRORS}); provisioning failed"
			exit 1
		fi

		# Small inter-AD jitter to spread API calls when cycling multiple ADs.
		[[ "${ad}" == "${AD_NUMBERS[-1]}" ]] \
			|| sleep "$(rand_in_range "${INTER_AD_MIN}" "${INTER_AD_MAX}")"
	done

	# Adjust backoff based on whether any AD was throttled this cycle.
	if (( throttled )); then
		BACKOFF_ATTEMPTS=$(( BACKOFF_ATTEMPTS + 1 ))
		(( BACKOFF_ATTEMPTS <= MAX_BACKOFF_ATTEMPTS )) || BACKOFF_ATTEMPTS="${MAX_BACKOFF_ATTEMPTS}"
	else
		(( BACKOFF_ATTEMPTS <= 0 )) || BACKOFF_ATTEMPTS=$(( BACKOFF_ATTEMPTS - 1 ))
	fi

	# Reset cumulative error counter when cycle was clean (transient-capacity-wait mode).
	(( cycle_errors > 0 )) || TOTAL_ERRORS=0

	sleep_for=$(compute_adaptive_sleep "${BACKOFF_ATTEMPTS}")
	cycle_log+=". Retrying in ${sleep_for}s."
	log_info "${cycle_log}"
	log_ad_details ad_log
	sleep "${sleep_for}"
done

log_error "max cycles (${MAX_CYCLES}) reached; provisioning failed"
exit 1
