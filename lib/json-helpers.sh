#!/usr/bin/env bash

set -euo pipefail

readonly FILE_LOCK_RETRY_ATTEMPTS=200  # 200 × 0.05s = 10s
readonly FILE_LOCK_RETRY_INTERVAL=0.05 # seconds

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

# Determine if a JSON value is valid and not empty
# Args: json
# Returns: 0 if valid, 1 if empty, 2 if the JSON cannot be parsed
is_valid_json() {
	local json="${1:-}"

	# Trim whitespace
	json="${json#"${json%%[![:space:]]*}"}"
	json="${json%"${json##*[![:space:]]}"}"

	[[ -n "${json}" ]] || return 1
	jq . <<<"${json}" >/dev/null 2>&1 || return 2

	local out
	out=$(jq -r '
		if (. == null)
		or ((type == "object" or type == "array") and (length == 0))
		or ((type == "string") and (gsub("[[:space:]]+"; "") | length == 0))
		then 1 else 0 end
	' <<<"${json}" 2>/dev/null) || return 2

	return "${out}"
}

# jq function: slugify string
# Output: jq function definition as string
jq_slugify() {
	cat <<-'EOF'
	def slugify:
		ascii_downcase
		| gsub(" "; "-")
		| gsub("[^a-z0-9-]"; "")
		| gsub("-+"; "-")
		| sub("^-"; "")
		| sub("-$"; "")
		| if length == 0 then "unnamed" else . end;
	EOF
}

# jq function: build hierarchical path from node map
# Output: jq function definition as string
# Note: Requires $nodes object with structure: {id: {name: "x", parent: "parent_id"}}
jq_build_path() {
	cat <<-'EOF'
	def build_path($nodes; $id):
		if $id == null then ""
		else
			($nodes[$id] // null) as $n |
			if $n == null then ""
			else
				if $n.parent == null then $n.name
				else (build_path($nodes; $n.parent) + "/" + $n.name)
				end
			end
		end;
	EOF
}

# Check if a field exists and is not null
# Args: json_string field_name
# Returns: 0 if field exists and not null, 1 otherwise
# Note: all arguments must be non-empty
has_json_field() {
	local json="${1}"
	local field="${2}"

	[[ -n "${json}" ]] || return 1
	[[ -n "${field}" ]] || return 1

	jq -e --arg field "${field}" '.[$field] != null' <<<"${json}" >/dev/null 2>&1
}

# Write a single section into the snapshot file, serialised via an atomic
# mkdir mutex. Safe to call from concurrent subshells or standalone.
# Args: err_var_name file_path jq_path json_value
# Example: write_section err_msg "$out" '.network.vcns' "$vcns_json"
# Returns: 0 on success, 1 on failure, 2 on usage error
# Sets: error message to err_var_name
write_section() {
	local err_var_name="${1:-}"
	local file="${2:-}"
	local path="${3:-}"
	local value="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${file}" ]]  || { err_ref="missing file path"; return 2; }
	[[ -n "${path}" ]]  || { err_ref="missing jq path"; return 2; }
	[[ -n "${value}" ]] || { err_ref="missing value"; return 2; }
	[[ -f "${file}" ]]  || { err_ref="file not found: ${file}"; return 1; }

	local dir
	dir="$(dirname -- "${file}")"
	[[ -d "${dir}" && -w "${dir}" ]] || {
		err_ref="directory not writable: ${dir}"
		return 1
	}

	# Acquire mutex: mkdir is POSIX-atomic; spin until acquired
	local lockdir="${file}.lock"
	local attempts=0
	until mkdir "${lockdir}" 2>/dev/null; do
		(( ++attempts >= FILE_LOCK_RETRY_ATTEMPTS )) && {
			err_ref="timed out waiting for section lock: ${lockdir}"
			return 1
		}
		sleep "${FILE_LOCK_RETRY_INTERVAL}"
	done

	local tmp_file
	tmp_file="$(mktemp -- "${file}.tmp.XXXXXX")" || {
		err_ref="cannot create temp file for ${file}"
		rmdir "${lockdir}" || err_ref+=$'\n'"failed to release section lock: ${lockdir}"
		return 1
	}

	local rc=0
	if jq --argjson v "${value}" "${path} = \$v" "${file}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${file}"
	else
		# shellcheck disable=SC2034
		err_ref="failed to write section ${path} to ${file}"
		rm -f -- "${tmp_file}"
		rc=1
	fi

	rmdir "${lockdir}" || {
		[[ -z "${err_ref}" || "${err_ref}" == *$'\n' ]] || err_ref+=$'\n'
		err_ref+="failed to release section lock: ${lockdir}"
		rc=1
	}

	return "${rc}"
}
