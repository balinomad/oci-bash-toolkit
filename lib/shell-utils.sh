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