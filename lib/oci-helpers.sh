#!/usr/bin/env bash

set -euo pipefail

# Read timeout applied to every OCI CLI call, in seconds.
# Mirrors the OCI CLI --read-timeout flag; 0 delegates to the OCI CLI default (60s).
# Override before sourcing or at any point before the first oci_capture_json call:
#   OCI_READ_TIMEOUT=120 ./discover.sh ...
OCI_READ_TIMEOUT="${OCI_READ_TIMEOUT:-0}"

# Execute OCI CLI command and capture JSON output and errors.
# The read timeout is controlled by the OCI_READ_TIMEOUT module variable above.
# Args: err_var_name profile oci_command...
#   err_var_name : name of caller variable to receive error message on failure
#   profile      : OCI CLI profile name
#   oci_command  : OCI CLI subcommand and arguments (passed through verbatim)
# Returns: 0 on success, OCI exit code on failure, 2 on usage error
# Output: JSON to stdout
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
	local -a oci_args=()
	local out err rc=0
	oci_args=( "$@" --profile "${profile}" --output json )
	[[ ${OCI_READ_TIMEOUT} -le 0 ]] || oci_args+=( --read-timeout "${OCI_READ_TIMEOUT}" )
	out="$(oci "$@" "${oci_args[@]}" 2>"${tmp_err}")" || rc=$?
	err="$(<"${tmp_err}")"
	rm -f -- "${tmp_err}"

	[[ ${rc} -eq 0 ]] || {
		# If stderr is empty, try to extract a message from stdout
		[[ -n "${err}" || ! "${out}" =~ Error:\ (.*) ]] || err="${BASH_REMATCH[1]%%$'\n'*}"
		err_ref="${err:-${out}}"
		return "${rc}"
	}

	[[ -n "${out}" ]] || {
		# OCI CLI returns empty string for empty results; normalise to typed empty
		local arg
		for arg in "$@"; do
			[[ "${arg}" != *'data[]'* ]] || { printf '%s\n' '[]'; return 0; }
		done
		printf '%s\n' '{}'
		return 0
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

	[[ -n "${file}" ]]    || { err_ref="missing config file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${file}" ]]    || { err_ref="config file ${file} not found"; return 1; }

	local tenancy_ocid rc=0 escaped_profile
	escaped_profile=$(printf '%s\n' "${profile}" | sed 's/[]\[^$.*/]/\\&/g')
	tenancy_ocid=$(
		sed -n "/^\[${escaped_profile}\]/,/^\[/{p}" "${file}" \
		| grep -E '^[[:space:]]*tenancy[[:space:]]*=' \
		| head -n1 \
		| cut -d= -f2- \
		| tr -d '[:space:]'
	) || rc=$?

	[[ ${rc} -eq 0 && -n "${tenancy_ocid}" ]] || {
		# shellcheck disable=SC2034
		err_ref="unable to extract tenancy OCID for profile ${profile}"
		return "${rc}"
	}

	printf '%s\n' "${tenancy_ocid}"
}