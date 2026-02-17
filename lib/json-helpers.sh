#!/usr/bin/env bash

set -euo pipefail

# Convert bash array of JSON strings to JSON array
# Args: json_string1 json_string2 ...
# Output: JSON array to stdout (empty array if no args)
to_json_array() {
	[[ $# -gt 0 ]] || { printf '[]\n'; return 0; }
	printf '%s\n' "$@" | jq -cs '.'
}

# Execute jq with error capture
# Useful to catch programming errors during development
# Args: err_var_name jq_args...
# Returns: 0 on success, 2 on jq error (programming error)
# Output: jq result to stdout
# Sets: error message to err_var_name
jq_safe() {
	local err_var_name="${1:-}"
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	shift

	[[ $# -gt 0 ]] || { err_ref='missing jq arguments'; return 2; }

	local jq_err
	jq_err="$(mktemp)" || { err_ref='cannot create temp file'; return 1; }

	local jq_out
	jq_out=$(jq "$@" 2>"${jq_err}") || {
		local rc=$?
		# shellcheck disable=SC2034
		err_ref="$(<"${jq_err}")"
		rm -f -- "${jq_err}"

		case ${rc} in
			2|3) return 2 ;;  # Programming errors (usage, compile)
			*)   return 1 ;;  # Runtime errors
		esac
	}

	rm -f -- "${jq_err}"
	printf '%s\n' "${jq_out}"
}

# Validate snapshot schema version
# Args: err_var_name file expected_schema
# Returns: 0 on success, 1 on validation failure, 2 on usage error
# Sets: error message to err_var_name
validate_snapshot_schema() {
	local err_var_name="${1:-}"
	local file="${2:-}"
	local expected_schema="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${file}" ]]            || { err_ref="missing file path"; return 2; }
	[[ -n "${expected_schema}" ]] || { err_ref="missing expected schema"; return 2; }
	[[ -f "${file}" ]]            || { err_ref="file not found: ${file}"; return 1; }

	local actual_schema
	actual_schema=$(jq -r '.meta.schema' "${file}" 2>/dev/null) || {
		err_ref="cannot read schema from ${file}"
		return 1
	}

	[[ "${actual_schema}" == "${expected_schema}" ]] || {
		# shellcheck disable=SC2034
		err_ref="schema mismatch: expected ${expected_schema}, got ${actual_schema}"
		return 1
	}
}
