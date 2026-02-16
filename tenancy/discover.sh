#!/usr/bin/env bash

# disover.sh - Discover OCI resources and generate a snapshot

# Check bash version
if [ -z "${BASH_VERSION}" ]; then
	echo "Error: This script requires bash" >&2
	exit 1
fi

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
	echo "Error: Bash 4.0+ required (you have ${BASH_VERSION})" >&2
	exit 1
fi

set -euo pipefail

readonly IGNORED_TAG_NAMESPACES=("Oracle-Tags")

# --- Utilities ---

# Print fatal error message and exit
fatal() {
	local msg="${1:-}"
	local rc="${2:-1}"
	printf 'Error: %s\n' "${msg}" >&2
	exit "${rc}"
}

# Print usage information
usage() {
	cat <<-EOF
	Usage: $(basename "$0") [OPTIONS]

	Options:
	  -p, --profile PROFILE       OCI CLI profile (default: DEFAULT)
	  -c, --config FILE           OCI config file (default: ~/.oci/config)
	  -o, --output FILE           Output snapshot file (default: auto-generated)
	  -h, --help                  Show this help message

	Environment variables:
	  OCI_PROFILE                 Same as --profile
	  OCI_CONFIG_FILE             Same as --config
	  OCI_SNAPSHOT_OUTPUT         Same as --output
	EOF
	exit 0
}

# Prefix with the script's directory if only a filename is given
prefix_with_script_dir() {
	local file="${1:-}"
	[[ "${file}" == */* ]] && printf '%s\n' "${file}" || printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${file}"
}

# Exit if required commands are not found
require_commands() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift
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
create_tmp_there() {
	local file_var_name="${1:-}"
	local err_var_name="${2:-}"

	# Validate the variable names and create namerefs
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ -n "${file_var_name}" ]] || { err_ref="missing variable name for temp file"; return 2; }
	local -n file_ref="${file_var_name}"
	file_ref=''

	# Remove optional "--" argument if present
	[[ "${1:-}" != "--" ]] || shift

	local where="${1:-}"
	[[ -n "${where}" ]] || { err_ref="missing existing file path"; return 2; }

	local dir base
	dir="$(dirname -- "${where}")"
	base="$(basename -- "${where}")"

	[[ -d "${dir}" && -w "${dir}" ]] || {
		err_ref="directory not writable: ${dir}";
		return 1
	}

	local tmp
	tmp="$(mktemp -- "${dir}/${base}.tmp.XXXXXX")" || {
		err_ref="cannot create temp file in ${dir}"
		return 1
	}

	# shellcheck disable=SC2034
	file_ref="${tmp}"
}

# --- OCI Helpers ---

# Capture OCI CLI JSON output and errors into named variables
# Args: json_var_name err_var_name [--] profile oci_command...
# Returns: 0 on success, OCI exit code on failure, 1-2 on usage errors
oci_capture_json() {
	local json_var_name="${1:-}"
	local err_var_name="${2:-}"

	# Validate the variable names and create namerefs
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ -n "${json_var_name}" ]] || { err_ref="missing json variable name"; return 2; }
	local -n json_ref="${json_var_name}"
	json_ref=''
	shift 2

	# Remove optional "--" argument if present
	[[ "${1:-}" != "--" ]] || shift

	local profile="${1:-}"; shift
	[[ -n "${profile}" ]] || { err_ref='missing profile name'; return 2; }

	local -a oci_cmd=("$@")

	# Validate command array
	local has_non_empty=0 word
	for word in "${oci_cmd[@]}"; do
		[[ -n "${word}" ]] && { has_non_empty=1; break; }
	done
	[[ ${has_non_empty} -eq 1 ]] || { err_ref='missing oci command'; return 2; }

	# Create temp file for errors
	local tmp_err
	tmp_err="$(mktemp)" || { err_ref='cannot create temp file'; return 1; }

	# Execute OCI command
	local out err rc
	set +e
	out="$(oci "${oci_cmd[@]}" --profile "${profile}" --output json 2> "${tmp_err}")"
	rc=$?
	set -e
	err="$(<"${tmp_err}")"
	rm -f -- "${tmp_err}"

	# shellcheck disable=SC2034
	[[ ${rc:-0} -gt 0 ]] || { json_ref="${out}"; return 0; }

	# If stderr is empty, extract error from stdout (format: "Error: message")
	[[ -n "${err}" || ! "${out}" =~ Error:\ (.*) ]] || err="${BASH_REMATCH[1]%%$'\n'*}"

	err_ref="${err:-$out}"
	return ${rc}
}

# Build a query string from a list of fields
build_query_field_list() {
	local list='' field
	for field in "$@"; do
		[[ -n "${list}" ]] && list+=", "
		list+="\"${field}\":\"${field}\""
	done
	printf '%s' "${list}"
}

# Build an OCI CLI query data attribute
query() {
	local filter='data'
	[[ $# -eq 0 ]] ||  {
		filter+=".{$(build_query_field_list "$@")}"
	}
	printf '%s\n' "--query"
	printf '%s\n' "${filter}"
}

# Build an OCI CLI query data attribute for an array
query_array() {
	local filter='data[]'
	[[ $# -eq 0 ]] ||  {
		filter+=".{$(build_query_field_list "$@")}"
	}
	printf '%s\n' "--query"
	printf '%s\n' "${filter}"
	printf '%s\n' "--all"
}

# Get tenancy OCID
get_tenancy_ocid() {
	local ocid_var_name="${1:-}"
	local err_var_name="${2:-}"

	# Validate the variable names and create namerefs
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ -n "${ocid_var_name}" ]] || { err_ref="missing tenancy OCID variable name"; return 2; }
	local -n ocid_ref="${ocid_var_name}"
	ocid_ref=''
	shift 2

	# Remove optional "--" argument if present
	[[ "${1:-}" != "--" ]] || shift

	local file="${1:-}"
	local profile="${2:-}"
	local rc
	local tenancy_ocid

	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${file}" ]] || { err_ref="missing config file name"; return 2; }
	[[ -f "${file}" ]] || { err_ref="config file ${file} not found"; return 1; }

	# Extract tenancy OCID
	set +e
	tenancy_ocid=$(
		sed -n "/^\[${profile}\]/,/^\[/{p}" "${file}" \
		| grep -E '^[[:space:]]*tenancy[[:space:]]*=' \
		| head -n1 \
		| cut -d= -f2- \
		| tr -d '[:space:]'
	)
	rc=$?
	set -e

	[[ ${rc:-0} -eq 0 && -n "${tenancy_ocid}" ]] || {
		err_ref="unable to extract tenancy OCID for profile ${profile}"
		return "${rc:-1}"
	}

	# shellcheck disable=SC2034
	ocid_ref="${tenancy_ocid}"
}

# Initialise snapshot
init_snapshot() {
	local err_var_name="${1:-}"
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	shift

	# Remove optional "--" argument if present
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local tmp_file file_err rc now
	now="$(date -u +"%Y-%m-%dT%H:%M:%S%z")"
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	if jq -n \
		--arg profile "${profile}" \
		--arg tenancy_id "${tenancy_ocid}" \
		--arg captured "${now}" \
		--argjson ignored "$(printf '%s\n' "${IGNORED_TAG_NAMESPACES[@]}" | jq -R . | jq -s .)" \
		'{
			meta: {
				schema: "oci.tenancy.discovery.v1",
				profile: $profile,
				"captured-at": $captured,
				ignored: {
					"tag-namespaces": $ignored
				}
			},
			iam: {
				tenancy: {
					id: $tenancy_id
				},
				"tag-namespaces": [],
				policies: [],
				users: [],
				groups: [],
				"dynamic-groups": [],
				"identity-domains": [],
				compartments: []
			},
			network: {
				vcns: [],
				drgs: [],
				nsgs: [],
				"public-ips": []
			}
		}' \
		> "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		# shellcheck disable=SC2034
		err_ref="failed to create new snapshot file ${out}"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# --- API Calls ---

# Get tenancy context
get_tenancy_info() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local oci_err rc tenancy_info
	mapfile -t query < <(query id name home-region-key description defined-tags freeform-tags)
	oci_capture_json tenancy_info oci_err -- "${profile}" iam tenancy get --tenancy-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${tenancy_info}" ]] || {
		err_ref="failed to get tenancy info: ${oci_err}"
		return "${rc}"
	}

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	if jq \
		--argjson tenancy "${tenancy_info}" \
		'.iam.tenancy = $tenancy' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with tenancy info"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# Get tag namespaces and tags
get_tags() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local oci_err rc

	# Get tag namespaces
	local namespaces
	mapfile -t query < <(query_array id name description is-retired defined-tags freeform-tags lifecycle-state)
	oci_capture_json namespaces oci_err -- "${profile}" iam tag-namespace list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${namespaces}" ]] || {
		err_ref="failed to get tag namespaces: ${oci_err}"
		return "${rc}"
	}

	# Populate tag namespaces
	local -a ns_arr ns_tags
	local ns ns_name ns_id ns_tag_list
	local tag_names tag_name tag
	while IFS= read -r ns; do
		ns_name=$(jq -r '.name' <<<"${ns}")
		ns_id=$(jq -r '.id' <<<"${ns}")
		[[ -n "${ns_id}" ]] || {
			err_ref+="unable to get namespace id for ${ns_name}"
			continue
		}

		ns=$(jq \
			--arg name "${ns_name}" \
			--argjson ignored "$(jq -c '.meta.ignored."tag-namespaces"' "${out}")" \
			'. + {ignored: ($ignored | index($name)) != null}' <<<"${ns}")

		mapfile -t query < <(query_array name)
		oci_capture_json tag_names oci_err -- "${profile}" iam tag list --tag-namespace-id "${ns_id}" "${query[@]}" || rc=$?
		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to list tag names for namespace ${ns_name}: ${oci_err}"
			rc=0; oci_err=''
			continue
		}

		ns_tags=()
		while IFS= read -r tag_name; do
			tag_name=$(jq -r '.name' <<<"${tag_name}")
			# Get tag definition
			mapfile -t query < <(query id name description is-cost-tracking is-retired defined-tags freeform-tags lifecycle-state validator)
			oci_capture_json tag oci_err -- "${profile}" iam tag get --tag-namespace-id "${ns_id}" --tag-name "${tag_name}" "${query[@]}" || rc=$?
			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to get tag definition for tag ${ns_name}.${tag_name}: ${oci_err}"
				rc=0; oci_err=''
				continue
			}

			# Add tag to namespace
			tag=$(jq \
				--arg name "${tag_name}" \
				--argjson ignored "$(jq -c '.meta.ignored."tag-definitions"' "${out}")" \
				'. + {ignored: ($ignored | index($name)) != null}' <<<"${tag}")
			ns_tags+=("${tag}")
		done < <(jq -c '.[]' <<<"${tag_names}")

		ns_tag_list="$(printf '%s\n' "${ns_tags[@]}" | jq -s '.')"
		ns=$(jq \
			--argjson tags "$(jq -c '. // []' <<<"${ns_tag_list}")" \
			'. + {"tag-definitions": $tags}' <<<"${ns}")

		ns_arr+=("${ns}")
	done < <(jq -c '.[]' <<<"${namespaces}")

	local ns_list
	ns_list="$(printf '%s\n' "${ns_arr[@]}" | jq -s '.')"

	# Get tag defaults
	local defaults
	mapfile -t query < <(query_array id value tag-namespace-id tag-definition-id tag-definition-name is-required lifecycle-state locks)
	oci_capture_json defaults oci_err -- "${profile}" iam tag-default list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to get tag defaults: ${oci_err}"
		return "${rc}"
	}

	# Populate tag defaults
	ns_list=$(jq \
		--argjson defs "$(jq -c '. // []' <<<"${defaults}")" \
		'map(
			. as $ns |
			."tag-definitions" |= (. // [] | map(
				. as $tag |
				. + {
					"tag-default": ( $defs | map(
							select(."tag-namespace-id" == $ns.id and ."tag-definition-id" == $tag.id)
							| {id, value, "is-required", "lifecycle-state", locks}
						) | first )
				}
			))
		)' <<<"${ns_list}")

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	# Write tag namespaces
	if jq \
		--argjson all_ns "$(jq -c '. // []' <<<"${ns_list}")" \
		'.iam."tag-namespaces" = $all_ns' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref+="failed to update ${out} with tag namespace ${ns_name}"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# Get policies
get_policies() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	# Get policies
	local -a query
	local oci_err rc policies
	mapfile -t query < <(query_array id name description statements defined-tags freeform-tags inactive-status lifecycle-state)
	oci_capture_json policies oci_err -- "${profile}" iam policy list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to get policies: ${oci_err}"
		return "${rc}"
	}

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	# Write policies
	if jq \
		--argjson policies "$(jq -c '. // []' <<<"${policies}")" \
		'.iam.policies = $policies' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with policies"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# Get users, user groups and their members
get_users() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local oci_err rc

	# Get users
	local users
	mapfile -t query < <(query_array id name description capabilities compartment-id external-identifier defined-tags freeform-tags inactive-status lifecycle-state)
	oci_capture_json users oci_err -- "${profile}" iam user list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${users}" ]] || {
		err_ref="failed to get users: ${oci_err}"
		return "${rc}"
	}

	# Get groups
	local groups
	mapfile -t query < <(query_array id name description compartment-id defined-tags freeform-tags inactive-status lifecycle-state)
	oci_capture_json groups oci_err -- "${profile}" iam group list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${groups}" ]] || {
		err_ref="failed to get groups: ${oci_err}"
		return "${rc}"
	}

	# Get additional information for each user
	local -a user_arr
	local user user_name user_id memberships api_keys
	while IFS= read -r user; do
		user_name=$(jq -r '.name' <<<"${user}")
		user_id=$(jq -r '.id' <<<"${user}")
		[[ -n "${user_id}" ]] || continue

		# Get group memberships
		mapfile -t query < <(query_array id name)
		oci_capture_json memberships oci_err -- "${profile}" \
			iam user list-groups --compartment-id "${tenancy_ocid}" --user-id "${user_id}" "${query[@]}" || rc=$?
		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to get group memberships for user ${user_name}: ${oci_err}"
			rc=0; oci_err=''
		}

		# Add memberships and API keys to user
		[[ -z "${memberships}" ]] || user=$(jq \
			--argjson memberships "$(jq -c '. // []' <<<"${memberships:-[]}")" \
			'."group-memberships" = $memberships' \
			<<<"${user}")

		# Get API keys
		mapfile -t query < <(query_array key-id key-value fingerprint inactive-status lifecycle-state)
		oci_capture_json api_keys oci_err -- "${profile}" \
			iam user api-key list --user-id "${user_id}" "${query[@]}" || rc=$?
		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to get API keys for user ${user_name}: ${oci_err}"
			rc=0; oci_err=''
		}

		[[ -z "${api_keys}" ]] || user=$(jq \
			--argjson api_keys "$(jq -c '. // []' <<<"${api_keys:-[]}")" \
			'."api-keys" = $api_keys' \
			<<<"${user}")

		user_arr+=("${user}")
	done < <(jq -c '.[]' <<<"${users}")

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref+="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	# Write users to snapshot
	local user_list
	user_list="$(printf '%s\n' "${user_arr[@]}" | jq -s '.')"

	if jq \
		--argjson groups "$(jq -c '. // []' <<<"${groups}")" \
		--argjson users "$(jq -c '. // []' <<<"${user_list}")" \
		'.iam |= (.groups = $groups | .users = $users)' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref+="failed to update ${out} with users"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# Get dynamic groups
get_dynamic_groups() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	# Get dynamic groups
	local -a query
	local oci_err rc
	local dynamic_groups
	mapfile -t query < <(query_array)
	oci_capture_json dynamic_groups oci_err -- "${profile}" iam dynamic-group list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${dynamic_groups}" ]] || {
		err_ref="failed to get dynamic groups: ${oci_err}"
		return "${rc}"
	}

	# Write dynamic groups to snapshot
	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	if jq \
		--argjson dyn_groups "$(jq -c '. // []' <<<"${dynamic_groups}")" \
		'.iam."dynamic-groups" = $dyn_groups' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with dynamic groups"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# Get identity domains
get_identity_domains() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local oci_err rc domains
	mapfile -t query < <(query_array id display-name description type url defined-tags freeform-tags home-region home-region-url \
		is-hidden-on-login license-type lifecycle-details lifecycle-state replica-regions)
	oci_capture_json domains oci_err -- "${profile}" iam domain list --compartment-id "${tenancy_ocid}" "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${domains}" ]] || {
		err_ref="failed to get identity domains: ${oci_err}"
		return "${rc}"
	}

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	if jq \
		--argjson domains "${domains}" \
		'.iam."identity-domains" = $domains' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with identity domains"
		rm -f -- "${tmp_file}"
		return 1
	fi

}

# Get compartments
get_compartments() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"
	local tenancy_ocid="${3:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local oci_err rc domains compartments
	mapfile -t query < <(query_array id name description compartment-id defined-tags freeform-tags inactive-status is-accessible lifecycle-state)
	oci_capture_json compartments oci_err -- "${profile}" iam compartment list --compartment-id "${tenancy_ocid}" \
		--access-level ANY --compartment-id-in-subtree true "${query[@]}" || rc=$?
	[[ ${rc:-0} -eq 0 && -n "${compartments}" ]] || {
		err_ref="failed to get compartments: ${oci_err}"
		return "${rc}"
	}

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	# Write compartments
	if jq \
		--argjson comps "$(jq -c '. // []' <<<"${compartments}")" \
		'.iam.compartments = $comps' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with compartments"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# Get virtual cloud networks
get_vcns() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	# Get all compartments from the snapshot
	local compartments
	compartments=$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")

	local -a query
	local oci_err rc

	# Get VCNs for each compartment
	local -a vcn_arr
	local vcns vcn vcn_id vcn_comp
	local subnets route_tables security_lists igws nat_gws service_gws drg_attachments

	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id compartment-id cidr-block cidr-blocks \
			default-dhcp-options-id default-route-table-id default-security-list-id \
			defined-tags display-name dns-label freeform-tags lifecycle-state vcn-domain-name)
		oci_capture_json vcns oci_err -- "${profile}" network vcn list \
			--compartment-id "${comp_id}" "${query[@]}" || rc=$?
		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to list VCNs for compartment ${comp_id}: ${oci_err}"
			rc=0; oci_err=''
			continue
		}

		while IFS= read -r vcn; do
			vcn_id=$(jq -r '.id' <<<"${vcn}")
			vcn_comp=$(jq -r '."compartment-id"' <<<"${vcn}")

			# Get subnets
			mapfile -t query < <(query_array id availability-domain cidr-block compartment-id \
				defined-tags dhcp-options-id display-name dns-label freeform-tags lifecycle-state \
				prohibit-internet-ingress prohibit-public-ip-on-vnic route-table-id \
				security-list-ids subnet-domain-name vcn-id)
			oci_capture_json subnets oci_err -- "${profile}" network subnet list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?
			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list subnets for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Get route tables
			mapfile -t query < <(query_array id compartment-id defined-tags display-name \
				freeform-tags lifecycle-state route-rules vcn-id)
			oci_capture_json route_tables oci_err -- "${profile}" network route-table list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?
			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list route tables for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Get security lists
			mapfile -t query < <(query_array id compartment-id defined-tags display-name \
				egress-security-rules freeform-tags ingress-security-rules lifecycle-state vcn-id)
			oci_capture_json security_lists oci_err -- "${profile}" network security-list list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?
			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list security lists for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Get internet gateways
			mapfile -t query < <(query_array id compartment-id defined-tags display-name \
				freeform-tags is-enabled lifecycle-state vcn-id)
			oci_capture_json igws oci_err -- "${profile}" network internet-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?
			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list internet gateways for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Get NAT gateways
			mapfile -t query < <(query_array id block-traffic compartment-id defined-tags \
				display-name freeform-tags lifecycle-state nat-ip public-ip-id vcn-id)
			oci_capture_json nat_gws oci_err -- "${profile}" network nat-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?
			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list NAT gateways for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Get service gateways
			mapfile -t query < <(query_array id block-traffic compartment-id defined-tags \
				display-name freeform-tags lifecycle-state route-table-id services vcn-id)
			oci_capture_json service_gws oci_err -- "${profile}" network service-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?

			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list service gateways for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Get DRG attachments for this VCN
			mapfile -t query < <(query_array id compartment-id defined-tags display-name drg-id \
				drg-route-table-id freeform-tags lifecycle-state network-details route-table-id vcn-id)
			oci_capture_json drg_attachments oci_err -- "${profile}" network drg-attachment list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}" || rc=$?

			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list DRG attachments for VCN ${vcn_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			# Combine all child resources into the VCN object
			vcn=$(jq \
				--argjson subnets "$(jq -c '. // []' <<<"${subnets:-[]}")" \
				--argjson route_tables "$(jq -c '. // []' <<<"${route_tables:-[]}")" \
				--argjson security_lists "$(jq -c '. // []' <<<"${security_lists:-[]}")" \
				--argjson igws "$(jq -c '. // []' <<<"${igws:-[]}")" \
				--argjson nat_gws "$(jq -c '. // []' <<<"${nat_gws:-[]}")" \
				--argjson service_gws "$(jq -c '. // []' <<<"${service_gws:-[]}")" \
				--argjson drg_attachments "$(jq -c '. // []' <<<"${drg_attachments:-[]}")" \
				'. + {
					subnets: $subnets,
					"route-tables": $route_tables,
					"security-lists": $security_lists,
					"internet-gateways": $igws,
					"nat-gateways": $nat_gws,
					"service-gateways": $service_gws,
					"drg-attachments": $drg_attachments
				}' <<<"${vcn}")

			vcn_arr+=("${vcn}")
		done < <(jq -c '.[]' <<<"${vcns}")
	done <<<"${compartments}"

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	local vcn_list
	vcn_list="$(printf '%s\n' "${vcn_arr[@]}" | jq -s '.')"

	if jq \
		--argjson vcns "$(jq -c '. // []' <<<"${vcn_list}")" \
		'.network.vcns = $vcns' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with virtual cloud networks"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# Get dynamic routing gateways
get_drgs() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	# Get all compartments from the snapshot
	local compartments
	compartments=$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")

	local -a query
	local oci_err rc

	local -a drg_arr
	local drgs drg

	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id compartment-id default-drg-route-tables \
			default-export-drg-route-distribution-id defined-tags display-name freeform-tags lifecycle-state)
		oci_capture_json drgs oci_err -- "${profile}" network drg list \
			--compartment-id "${comp_id}" "${query[@]}" || rc=$?
		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to list DRGs for compartment ${comp_id}: ${oci_err}"
			rc=0; oci_err=''
			continue
		}

		while IFS= read -r drg; do
			drg_arr+=("${drg}")
		done < <(jq -c '.[]' <<<"${drgs}")
	done <<<"${compartments}"

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	local drg_list
	drg_list="$(printf '%s\n' "${drg_arr[@]}" | jq -s '.')"

	if jq \
		--argjson drgs "$(jq -c '. // []' <<<"${drg_list:-[]}")" \
		'.network.drgs = $drgs' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with dynamic routing gateways"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# Get network security groups
get_nsgs() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	# Get all compartments from the snapshot
	local compartments
	compartments=$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")

	local -a query
	local oci_err rc

	local -a nsg_arr
	local nsgs nsg nsg_id nsg_rules

	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id compartment-id defined-tags display-name \
			freeform-tags lifecycle-state vcn-id)
		oci_capture_json nsgs oci_err -- "${profile}" network nsg list \
			--compartment-id "${comp_id}" "${query[@]}" || rc=$?

		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to list NSGs for compartment ${comp_id}: ${oci_err}"
			rc=0; oci_err=''
			continue
		}

		while IFS= read -r nsg; do
			nsg_id=$(jq -r '.id' <<<"${nsg}")

			# Get NSG rules
			mapfile -t query < <(query_array id description destination destination-type direction \
				icmp-options is-stateless is-valid protocol source source-type tcp-options udp-options)
			oci_capture_json nsg_rules oci_err -- "${profile}" network nsg rules list \
				--nsg-id "${nsg_id}" "${query[@]}" || rc=$?

			[[ ${rc:-0} -eq 0 ]] || {
				err_ref+="unable to list rules for NSG ${nsg_id}: ${oci_err}"
				rc=0; oci_err=''
			}

			nsg=$(jq \
				--argjson rules "$(jq '. // []' <<<"${nsg_rules}")" \
				'. + {rules: $rules}' <<<"${nsg}")

			nsg_arr+=("${nsg}")
		done < <(jq -c '.[]' <<<"${nsgs}")
	done <<<"${compartments}"

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	local nsg_list
	nsg_list="$(printf '%s\n' "${nsg_arr[@]}" | jq -s '.')"

	if jq \
		--argjson nsgs "$(jq -c '. // []' <<<"${nsg_list:-[]}")" \
		'.network.nsgs = $nsgs' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with network security groups"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# Get public IP addresses
get_public_ips() {
	local err_var_name="${1:-}"; shift
	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''
	[[ "${1:-}" != "--" ]] || shift

	local out="${1:-}"
	local profile="${2:-}"

	[[ -n "${out}" ]] || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]] || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	# Get all compartments from the snapshot
	local compartments
	compartments=$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")

	local -a query
	local oci_err rc

	# Collect all public IPs across compartments
	printf '%s\n' "  [$(date +"%Y-%m-%d %H:%M:%S")] Processing Public IPs"
	local -a public_ip_arr
	local public_ips public_ip

	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id assigned-entity-id assigned-entity-type \
			availability-domain compartment-id defined-tags display-name freeform-tags \
			ip-address lifecycle-state lifetime private-ip-id public-ip-pool-id scope)
		oci_capture_json public_ips oci_err -- "${profile}" network public-ip list \
			--compartment-id "${comp_id}" --scope REGION "${query[@]}" || rc=$?

		[[ ${rc:-0} -eq 0 ]] || {
			err_ref+="unable to list public IPs for compartment ${comp_id}: ${oci_err}"
			rc=0; oci_err=''
			continue
		}

		while IFS= read -r public_ip; do
			public_ip_arr+=("${public_ip}")
		done < <(jq -c '.[]' <<<"${public_ips}")
	done <<<"${compartments}"

	local public_ip_list
	public_ip_list="$(printf '%s\n' "${public_ip_arr[@]}" | jq -s '.')"

	local tmp_file file_err
	create_tmp_there tmp_file file_err -- "${out}" || rc=$?
	[[ ${rc:-0} -eq 0 ]] || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return "${rc}"
	}

	if jq \
		--argjson public_ips "$(jq -c '. // []' <<<"${public_ip_list:-[]}")" \
		'.network."public-ips" = $public_ips' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to update ${out} with public IPs"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# --- Parse Arguments ---

# Start with defaults
PROFILE="${OCI_PROFILE:-DEFAULT}"
CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
OUT="${OCI_SNAPSHOT_OUTPUT:-}"

# Override with flags if provided
while [[ $# -gt 0 ]]; do
	case "$1" in
		-p|--profile)
			PROFILE="${2:-}"
			[[ -n "${PROFILE}" ]] || fatal "profile cannot be empty"
			shift 2
			;;
		-c|--config)
			CONFIG_FILE="${2:-}"
			[[ -n "${CONFIG_FILE}" ]] || fatal "config file cannot be empty"
			shift 2
			;;
		-o|--output)
			OUT="${2:-}"
			[[ -n "${OUT}" ]] || fatal "output file cannot be empty"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			fatal "unknown option: $1 (use --help for usage)"
			;;
	esac
done

# --- Configuration ---

err_msg=''
require_commands err_msg -- jq oci sed grep head cut tr date mktemp || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "${err_msg}" "${rc}"

# trap cleanup EXIT INT TERM

# Auto-generate output filename if not specified
[[ -n "${OUT}" ]] || OUT=$(prefix_with_script_dir "snapshot-${PROFILE,,}-$(date +%Y%m%d%H%M%S).json")

# Validate OCI config exists
[[ -f "${CONFIG_FILE}" ]] || fatal "OCI config file not found: ${CONFIG_FILE}"

# --- Main ---

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S %Z")] Initializing snapshot"
get_tenancy_ocid TENANCY_OCID err_msg -- "${CONFIG_FILE}" "${PROFILE}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to find tenancy OCID: ${err_msg}" "${rc}"
# shellcheck disable=SC2153
init_snapshot err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to initialize snapshot: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering tenancy info"
get_tenancy_info err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set tenancy info: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering tags"
get_tags err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set tags: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering policies"
get_policies err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set policies: ${err_msg}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering users"
get_users err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set users: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering dynamic groups"
get_dynamic_groups err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set dynamic groups: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering identity domains"
get_identity_domains err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set identity domains: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering compartments"
get_compartments err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set compartments: ${err_msg}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering virtual cloud networks"
get_vcns err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set VCNs: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering dynamic routing gateways"
get_drgs err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set networking: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Discovering network security lists"
get_nsgs err_msg -- "${OUT}" "${PROFILE}" "${TENANCY_OCID}" || rc=$?
[[ ${rc:-0} -eq 0 ]] || fatal "unable to set networking: ${err_msg}" "${rc}"

printf '%s\n' "[$(date +"%Y-%m-%d %H:%M:%S")] Snapshot complete"
