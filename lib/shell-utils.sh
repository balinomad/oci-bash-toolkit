#!/usr/bin/env bash

set -euo pipefail

# Check if required commands are available
# Args: err_var_name command1 command2 ...
# Returns: 0 if all found, 1 if missing, 2 on usage error
# Sets: error message to err_var_name
require_commands() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ $# -gt 0 ]] || return 0

	local cmd missing=()
	for cmd in "$@"; do
		command -v -- "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
	done

	[[ ${#missing[@]} -ne 0 ]] || return 0

	err_ref="required commands missing: ${missing[*]}"
	return 1
}

# Create a temporary file in the same directory as an existing file
# Args: err_var_name existing_file_path
# Returns: 0 on success, 1 on failure, 2 on usage error
# Output: Temp file path to stdout
# Sets: error message to err_var_name
mktemp_sibling() {
	local err_var_name="${1:-}"
	local where="${2:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${where}" ]] || { err_ref="missing existing file path"; return 2; }

	local dir base
	dir="$(dirname -- "${where}")"
	base="$(basename -- "${where}")"

	[[ -d "${dir}" && -w "${dir}" ]] || {
		err_ref="directory not writable: ${dir}"
		return 1
	}

	local tmp
	tmp="$(mktemp -- "${dir}/${base}.tmp.XXXXXX")" || {
		# shellcheck disable=SC2034
		err_ref="cannot create temp file in ${dir}"
		return 1
	}

	printf '%s\n' "${tmp}"
}

# Print fatal error message and exit
# Args: message [exit_code]
# Side effects: exits the script with exit_code (default 1)
fatal() {
	local msg="${1:-}"
	local rc="${2:-1}"

	while [[ $msg == *$'\n' ]]; do
		msg="${msg%$'\n'}"
	done

	printf 'Error: %s\n' "${msg}" >&2
	exit "${rc}"
}

# Print timestamped progress message unless quiet
# Args: quiet message...
# quiet: "true" suppresses output; any other value prints to stderr
log_progress() {
	local quiet="${1:-false}"; shift
	[[ "${quiet}" == "true" ]] || printf '%s\n' "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Derive output filename by inserting a suffix before .json extension
# Args: input_file suffix
# Example: derive_output_file "snapshot-prod.json" "plan" → "snapshot-prod.plan.json"
# Output: input.suffix.json
derive_output_file() {
	local input="${1:-}"
	local suffix="${2:-}"
	[[ -n "${input}" ]] && [[ -n "${suffix}" ]] || return 2

	local dir base stem
	dir="$(dirname -- "${input}")"
	base="$(basename -- "${input}")"
	stem="${base%.json}"

	printf '%s\n' "${dir}/${stem}.${suffix}.json"
}

# Delimiter for job array
arg_delimiter() {
	printf '%s\n' $'\x1F'
}

# Add a job to the job array
add_job() {
	local jobs_arr_name="${1:-}"
	local name="${2:-}"

	[[ -n "${jobs_arr_name}" ]] || {
		log_progress "${quiet}" "missing jobs array name"
		return 2
	}
	local -n jobs_ref="${jobs_arr_name}"

	[[ -n "${name}" ]] || {
		log_progress "${quiet}" "missing job name"
		return 2
	}
	shift 2

	[[ $# -gt 0 ]] || {
		log_progress "${quiet}" "missing job function"
		return 2
	}

	local IFS
	IFS="$(arg_delimiter)"
	jobs_ref["$name"]="$*"
}

# Run jobs concurrently
# run_jobs quiet jobs_array_name
# jobs_array_name: name of an array whose elements are names of job arrays
# Each job entry is: "<func>␟<arg1>␟<arg2>..."
# Returns: 0 on success, 1 on failure, 2 on usage error
run_jobs() {
	local quiet="${1:-false}"
	local jobs_arr_name="${2:-}"

	[[ -n "${jobs_arr_name}" ]] || {
		log_progress "${quiet}" "missing jobs array name"
		return 2
	}
	# shellcheck disable=SC2178
	local -n jobs_ref="${jobs_arr_name}"

	local total_jobs=${#jobs_ref[@]}
	[[ ${total_jobs} -gt 0 ]] || return 0

	local -a prc
	coproc prc { cat; }
	# shellcheck disable=SC2086
	exec {rfd}<&${prc[0]}- || true
	# shellcheck disable=SC2086
	exec {wfd}>&${prc[1]}- || true

	# reader runs concurrently
	{
		local record received=0 rc=0
		while IFS= read -r -d '' -u "${rfd}" record; do
			local job_rc msg
			IFS=$'\t' read -r job_rc msg <<< "${record}"
			[[ $job_rc -eq 0 ]] || rc=1
			log_progress "${quiet}" "  - ${msg}"
			(( ++received ))
			[[ received -lt total_jobs ]] || break
		done
		exit "${rc}"
	} &
	local reader_pid=$!

	# Launch jobs: each worker writes a single framed payload to the coproc
	local label
	for label in "${!jobs_ref[@]}"; do
		local IFS
		IFS="$(arg_delimiter)"
		# shellcheck disable=SC2086
		set -- ${jobs_ref[$label]}
		local func="${1:-}"
		[[ -n "${func}" ]] || {
			log_progress "${quiet}" "job ${label} missing function name"
			continue
		}
		shift
		local -a args=("$@")
		unset IFS
		(
			local rc=0 func_err log_msg
			"${func}" func_err "${args[@]}" 2>&1 || rc=$?
			log_msg="${label}: success"
			[[ $rc -eq 0 ]] || log_msg="${label}: error (exit ${rc}): ${func_err:-unknown error}"
			printf '%d\t%s\0' "${rc}" "${log_msg}" >&"${wfd}"
			exit "${rc}"
		) &
	done

	local rc=0
	wait "${reader_pid}" || rc=$?

	exec {rfd}<&- || true
	exec {wfd}>&- || true

	return "${rc}"
}
