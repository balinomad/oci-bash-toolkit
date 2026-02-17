#!/usr/bin/env bash

set -euo pipefail

# Execute OCI CLI command and capture JSON output and errors
# Args: err_var_name profile oci_command...
# Returns: 0 on success, OCI exit code on failure, 2 on usage error
# Output: JSON
# Sets: error message to err_var_name on failure
oci_capture_json() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	local profile="${1:-}"; shift
	[[ -n "${profile}" ]] || { err_ref='missing profile name'; return 2; }

	[[ $# -gt 0 ]] || { err_ref='missing oci command'; return 2; }

	# Create temp file for errors
	local tmp_err
	tmp_err="$(mktemp)" || { err_ref='cannot create temp file'; return 1; }

	# Execute OCI command
	local out err rc
	out="$(oci "$@" --profile "${profile}" --output json 2> "${tmp_err}")" || rc=$?
	err="$(<"${tmp_err}")"
	rm -f -- "${tmp_err}"

	[[ ${rc:-0} -eq 0 ]] || {
		# If stderr is empty, extract error from stdout (format: "Error: message")
		[[ -n "${err}" || ! "${out}" =~ Error:\ (.*) ]] || err="${BASH_REMATCH[1]%%$'\n'*}"
		err_ref="${err:-$out}"
		return ${rc}
	}

	[[ -n "${out}" ]] || {
		# OCI CLI returns empty string for empty results
		# Check if query expects array and return empty array, otherwise empty object
		local arg
		for arg in "$@"; do
			[[ "${arg}" != *'data[]'* ]] || { printf '%s\n' '[]'; return 0; }
		done
		printf '%s\n' '{}'
	}

	printf '%s\n' "${out}"
}

# Build a query string from a list of fields
# Args: field1 field2 ...
# Output: JSON-like field list string for --query parameter
build_query_field_list() {
	local list='' field
	for field in "$@"; do
		[[ -n "${list}" ]] && list+=", "
		list+="\"${field}\":\"${field}\""
	done
	printf '%s' "${list}"
}

# Build an OCI CLI query for a single object
# Args: [field1 field2 ...]
# Output: --query data.{fields} (or just data if no fields)
query() {
	local filter='data'
	[[ $# -eq 0 ]] || filter+=".{$(build_query_field_list "$@")}"
	printf '%s\n' "--query"
	printf '%s\n' "${filter}"
}

# Build an OCI CLI query for an array of objects
# Args: [field1 field2 ...]
# Output: --query data[].{fields} --all (or just data[] --all if no fields)
query_array() {
	local filter='data[]'
	[[ $# -eq 0 ]] || filter+=".{$(build_query_field_list "$@")}"
	printf '%s\n' "--query"
	printf '%s\n' "${filter}"
	printf '%s\n' "--all"
}

# Get tenancy OCID from OCI config file
# Args: err_var_name config_file profile
# Returns: 0 on success, 1 on failure, 2 on usage error
# Output: tenancy OCID
# Sets: error message to err_var_name on failure
get_tenancy_ocid() {
	local err_var_name="${1:-}"
	local file="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${file}" ]] || { err_ref="missing config file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${file}" ]] || { err_ref="config file ${file} not found"; return 1; }

	local tenancy_ocid rc escaped_profile
    escaped_profile=$(printf '%s\n' "${profile}" | sed 's/[]\[^$.*/]/\\&/g')
	tenancy_ocid=$(
		sed -n "/^\[${escaped_profile}\]/,/^\[/{p}" "${file}" \
		| grep -E '^[[:space:]]*tenancy[[:space:]]*=' \
		| head -n1 \
		| cut -d= -f2- \
		| tr -d '[:space:]'
	) || rc=$?

	[[ ${rc:-0} -eq 0 && -n "${tenancy_ocid}" ]] || {
		# shellcheck disable=SC2034
		err_ref="unable to extract tenancy OCID for profile ${profile}"
		return "${rc:-1}"
	}

	printf '%s\n' "${tenancy_ocid}"
}