#!/usr/bin/env bash

# discover.sh - Discover OCI resources and generate a snapshot

# Bash version check
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../lib" && pwd)/bash-version-check.sh"

set -euo pipefail

# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/../lib"

source "${LIB_DIR}/shell-utils.sh"
source "${LIB_DIR}/oci-helpers.sh"
source "${LIB_DIR}/json-helpers.sh"

# shellcheck disable=SC2034
readonly SCHEMA_VERSION="oci.tenancy.discovery.v1"
# shellcheck disable=SC2034
readonly SCHEMA_SECTIONS=("iam" "network" "storage" "certificates" "dns")

# Oracle-managed tags cannot be cloned
readonly IGNORED_TAG_NAMESPACES=("Oracle-Tags")

# Print fatal error message and exit
fatal() {
	local msg="${1:-}"
	local rc="${2:-1}"

	# Remove trailing newlines
	while [[ $msg == *$'\n' ]]; do
		msg="${msg%$'\n'}"
	done

	printf 'Error: %s\n' "${msg}" >&2
	exit "${rc}"
}

# Print progress message unless --quiet
log_progress() {
	[[ "${QUIET}" == "true" ]] || printf '%s\n' "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Print usage information
usage() {
	cat <<-EOF
	Usage: $(basename "$0") [OPTIONS]

	Options:
	  -p, --profile PROFILE       OCI CLI profile (default: DEFAULT)
	  -c, --config FILE           OCI config file (default: ~/.oci/config)
	  -o, --output FILE           Output snapshot file (default: auto-generated)
	  -q, --quiet                 Suppress progress output
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

# Initialise snapshot
init_snapshot() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"
	local schema="${5:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq -n \
		--arg profile "${profile}" \
		--arg tenancy_id "${tenancy_ocid}" \
		--arg schema "${schema}" \
		--arg captured "$(date -u -Iseconds)" \
		--argjson ignored "$(printf '%s\n' "${IGNORED_TAG_NAMESPACES[@]}" | jq -R . | jq -s .)" \
		'{
			meta: {
				schema: $schema,
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
		err_ref="failed to create new snapshot file ${out}"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# Get tenancy context
extract_tenancy_info() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local tenancy_info oci_err
	mapfile -t query < <(query id name home-region-key description defined-tags freeform-tags)
	tenancy_info=$(oci_capture_json oci_err "${profile}" iam tenancy get --tenancy-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get tenancy info: ${oci_err}"
		return $?
	}

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
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
extract_tags() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	# Cache ignored namespaces list
	local ignored_ns
	ignored_ns=$(jq -c '.meta.ignored."tag-namespaces"' "${out}")

	local -a query
	local oci_err

	# Get tag namespaces
	local namespaces
	mapfile -t query < <(query_array id name description is-retired defined-tags freeform-tags lifecycle-state)
	namespaces=$(oci_capture_json oci_err "${profile}" iam tag-namespace list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get tag namespaces: ${oci_err}"
		return $?
	}

	# Populate tag namespaces
	local -a ns_arr
	local -a ns_tags
	local ns ns_name ns_id
	local tag_names tag_name tag
	while IFS= read -r ns; do
		ns_name=$(jq -r '.name' <<<"${ns}")
		ns_id=$(jq -r '.id' <<<"${ns}")
		[[ -n "${ns_id}" ]] || {
			# Continue on individual resource errors to capture partial snapshot
			err_ref+="unable to get namespace id for ${ns_name:-<unknown>}"$'\n'
			continue
		}

		ns=$(jq \
			--arg name "${ns_name}" \
			--argjson ignored "${ignored_ns}" \
			'. + { ignored: ($ignored | index($name)) != null }' <<<"${ns}")

		mapfile -t query < <(query_array name)
		tag_names=$(oci_capture_json oci_err "${profile}" iam tag list --tag-namespace-id "${ns_id}" "${query[@]}") || {
			[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
			err_ref+="unable to list tag names for namespace ${ns_name}: ${oci_err}"
			oci_err=''
			continue
		}

		# Get all tags
		ns_tags=()
		while IFS= read -r tag_name; do
			tag_name=$(jq -r '.name' <<<"${tag_name}")
			mapfile -t query < <(query id name description is-cost-tracking is-retired defined-tags freeform-tags lifecycle-state validator)
			tag=$(oci_capture_json oci_err "${profile}" iam tag get --tag-namespace-id "${ns_id}" --tag-name "${tag_name}" "${query[@]}") || {
				[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
				err_ref+="unable to get tag definition for tag ${ns_name}.${tag_name}: ${oci_err}"
				oci_err=''
				continue
			}

			ns_tags+=("${tag}")
		done < <(jq -c '.[]' <<<"${tag_names}")

		ns=$(jq \
			--argjson tags "$(to_json_array "${ns_tags[@]}")" \
			'. + { "tag-definitions": $tags }' <<<"${ns}")

		ns_arr+=("${ns}")
	done < <(jq -c '.[]' <<<"${namespaces}")

	# Get tag defaults
	local defaults
	mapfile -t query < <(query_array id value tag-namespace-id tag-definition-id tag-definition-name is-required lifecycle-state locks)
	defaults=$(oci_capture_json oci_err "${profile}" iam tag-default list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get tag defaults: ${oci_err}"
		return $?
	}

	# Populate tag defaults
	local ns_list
	ns_list=$(jq \
		--argjson defs "${defaults}" \
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
		)' <<<"$(to_json_array "${ns_arr[@]}")")

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	# Write tag namespaces
	if jq \
		--argjson all_ns "${ns_list}" \
		'.iam."tag-namespaces" = $all_ns' \
		"${out}" > "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref+="failed to update ${out} with tag namespaces"
		rm -f -- "${tmp_file}"
		return 1
	fi

	[[ -z "${err_ref}" ]] || return 1
}

# Get policies
extract_policies() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	# Get policies
	local -a query
	local policies oci_err
	mapfile -t query < <(query_array id name description statements defined-tags freeform-tags inactive-status lifecycle-state)
	policies=$(oci_capture_json oci_err "${profile}" iam policy list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get policies: ${oci_err}"
		return $?
	}

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	# Write policies
	if jq \
		--argjson policies "${policies}" \
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
extract_users() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local oci_err

	# Get users
	local users
	mapfile -t query < <(query_array id name description capabilities compartment-id external-identifier defined-tags \
		freeform-tags inactive-status lifecycle-state)
	users=$(oci_capture_json oci_err "${profile}" iam user list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get users: ${oci_err}"
		return $?
	}

	# Get groups
	local groups
	mapfile -t query < <(query_array id name description compartment-id defined-tags freeform-tags inactive-status lifecycle-state)
	groups=$(oci_capture_json oci_err "${profile}" iam group list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get groups: ${oci_err}"
		return $?
	}

	# Get additional information for each user
	local -a user_arr
	local user user_name user_id memberships api_keys
	while IFS= read -r user; do
		user_name=$(jq -r '.name' <<<"${user}")
		user_id=$(jq -r '.id' <<<"${user}")
		[[ -n "${user_id}" ]] || {
			err_ref+="unable to get user id for ${user_name:-<unknown>}"$'\n'
			continue
		}

		# Get group memberships
		mapfile -t query < <(query_array id name)
		memberships=$(oci_capture_json oci_err "${profile}" \
			iam user list-groups --compartment-id "${tenancy_ocid}" --user-id "${user_id}" "${query[@]}") || {
				[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
				err_ref+="unable to get group memberships for user ${user_name}: ${oci_err}"
				oci_err=''
				memberships='[]'
		}

		# Get API keys
		mapfile -t query < <(query_array key-id key-value fingerprint inactive-status lifecycle-state)
		api_keys=$(oci_capture_json oci_err "${profile}" \
			iam user api-key list --user-id "${user_id}" "${query[@]}") || {
				[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
				err_ref+="unable to get API keys for user ${user_name}: ${oci_err}"
				oci_err=''
				api_keys='[]'
		}

		user=$(jq \
			--argjson memberships "${memberships}" \
			--argjson api_keys "${api_keys}" \
			'. + {
				"group-memberships": $memberships,
				"api-keys": $api_keys
			}' <<<"${user}")

		user_arr+=("${user}")
	done < <(jq -c '.[]' <<<"${users}")

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref+="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq \
		--argjson groups "${groups}" \
		--argjson users "$(to_json_array "${user_arr[@]}")" \
		'.iam += {
			groups: $groups,
			users: $users
		}' \
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
extract_dynamic_groups() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	# Get dynamic groups
	local -a query
	local dynamic_groups oci_err
	mapfile -t query < <(query_array)
	dynamic_groups=$(oci_capture_json oci_err "${profile}" iam dynamic-group list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get dynamic groups: ${oci_err}"
		return $?
	}

	# Write dynamic groups to snapshot
	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq \
		--argjson dyn_groups "${dynamic_groups}" \
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
extract_identity_domains() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local domains oci_err
	mapfile -t query < <(query_array id display-name description type url defined-tags freeform-tags home-region home-region-url \
		is-hidden-on-login license-type lifecycle-details lifecycle-state replica-regions)
	domains=$(oci_capture_json oci_err "${profile}" iam domain list --compartment-id "${tenancy_ocid}" "${query[@]}") || {
		err_ref="failed to get identity domains: ${oci_err}"
		return $?
	}

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
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
extract_compartments() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"
	local tenancy_ocid="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]          || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }

	local -a query
	local compartments oci_err
	mapfile -t query < <(query_array id name description compartment-id defined-tags freeform-tags inactive-status is-accessible lifecycle-state)
	compartments=$(oci_capture_json oci_err "${profile}" iam compartment list --compartment-id "${tenancy_ocid}" \
		--access-level ANY --compartment-id-in-subtree true "${query[@]}") || {
			err_ref="failed to get compartments: ${oci_err}"
			return $?
	}

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	# Write compartments
	if jq \
		--argjson comps "${compartments}" \
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
extract_vcns() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	local -a query
	local oci_err

	# Get VCNs for each compartment
	local -a vcn_arr
	local vcns vcn vcn_name vcn_id vcn_comp
	local subnets route_tables security_lists igws nat_gws service_gws drg_attachments
	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id compartment-id cidr-block cidr-blocks \
			default-dhcp-options-id default-route-table-id default-security-list-id \
			defined-tags display-name dns-label freeform-tags lifecycle-state vcn-domain-name)
		vcns=$(oci_capture_json oci_err "${profile}" network vcn list --compartment-id "${comp_id}" "${query[@]}") || {
			[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
			err_ref+="unable to list VCNs for compartment ${comp_id}: ${oci_err}"
			oci_err=''
			continue
		}

		while IFS= read -r vcn; do
			vcn_name=$(jq -r '."display-name"' <<<"${vcn}")
			vcn_id=$(jq -r '.id' <<<"${vcn}")
			vcn_comp=$(jq -r '."compartment-id"' <<<"${vcn}")

			# Get subnets
			mapfile -t query < <(query_array id availability-domain cidr-block compartment-id \
				defined-tags dhcp-options-id display-name dns-label freeform-tags lifecycle-state \
				prohibit-internet-ingress prohibit-public-ip-on-vnic route-table-id \
				security-list-ids subnet-domain-name vcn-id)
			subnets=$(oci_capture_json oci_err "${profile}" network subnet list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list subnets for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					subnets='[]'
			}

			# Get route tables
			mapfile -t query < <(query_array id compartment-id defined-tags display-name \
				freeform-tags lifecycle-state route-rules vcn-id)
			route_tables=$(oci_capture_json oci_err "${profile}" network route-table list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list route tables for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					route_tables='[]'
			}

			# Get security lists
			mapfile -t query < <(query_array id compartment-id defined-tags display-name \
				egress-security-rules freeform-tags ingress-security-rules lifecycle-state vcn-id)
			security_lists=$(oci_capture_json oci_err "${profile}" network security-list list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list security lists for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					security_lists='[]'
			}

			# Get internet gateways
			mapfile -t query < <(query_array id compartment-id defined-tags display-name \
				freeform-tags is-enabled lifecycle-state vcn-id)
			igws=$(oci_capture_json oci_err "${profile}" network internet-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list internet gateways for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					igws='[]'
			}

			# Get NAT gateways
			mapfile -t query < <(query_array id block-traffic compartment-id defined-tags \
				display-name freeform-tags lifecycle-state nat-ip public-ip-id vcn-id)
			nat_gws=$(oci_capture_json oci_err "${profile}" network nat-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list NAT gateways for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					nat_gws='[]'
			}

			# Get service gateways
			mapfile -t query < <(query_array id block-traffic compartment-id defined-tags \
				display-name freeform-tags lifecycle-state route-table-id services vcn-id)
			service_gws=$(oci_capture_json oci_err "${profile}" network service-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list service gateways for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					service_gws='[]'
			}

			# Get DRG attachments
			mapfile -t query < <(query_array id compartment-id defined-tags display-name drg-id \
				drg-route-table-id freeform-tags lifecycle-state network-details route-table-id vcn-id)
			drg_attachments=$(oci_capture_json oci_err "${profile}" network drg-attachment list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query[@]}") || {
					[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
					err_ref+="unable to list DRG attachments for VCN ${vcn_name}: ${oci_err}"
					oci_err=''
					drg_attachments='[]'
			}

			# Combine all child resources into the VCN object
			vcn=$(jq \
				--argjson subnets "${subnets}" \
				--argjson route_tables "${route_tables}" \
				--argjson security_lists "${security_lists}" \
				--argjson igws "${igws}" \
				--argjson nat_gws "${nat_gws}" \
				--argjson service_gws "${service_gws}" \
				--argjson drg_attachments "${drg_attachments}" \
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
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq \
		--argjson vcns "$(to_json_array "${vcn_arr[@]}")" \
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
extract_drgs() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	local -a query
	local -a drg_arr=()
	local drgs oci_err
	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id compartment-id default-drg-route-tables \
			default-export-drg-route-distribution-id defined-tags display-name freeform-tags lifecycle-state)
		drgs=$(oci_capture_json oci_err "${profile}" network drg list --compartment-id "${comp_id}" "${query[@]}") || {
			[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
			err_ref+="unable to list DRGs for compartment ${comp_id}: ${oci_err}"
			oci_err=''
			continue
		}
		mapfile -t -O "${#drg_arr[@]}" drg_arr < <(jq -c '.[]' <<<"${drgs}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq \
		--argjson drgs "$(to_json_array "${drg_arr[@]}")" \
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
extract_nsgs() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	local -a query
	local -a nsg_arr=()
	local nsgs nsg nsg_name nsg_id nsg_rules oci_err
	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id compartment-id defined-tags display-name \
			freeform-tags lifecycle-state vcn-id)
		nsgs=$(oci_capture_json oci_err "${profile}" network nsg list --compartment-id "${comp_id}" "${query[@]}") || {
			[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
			err_ref+="unable to list NSGs for compartment ${comp_id}: ${oci_err}"
			oci_err=''
			continue
		}

		while IFS= read -r nsg; do
			nsg_name=$(jq -r '."display-name"' <<<"${nsg}")
			nsg_id=$(jq -r '.id' <<<"${nsg}")

			# Get NSG rules
			mapfile -t query < <(query_array id description destination destination-type direction \
				icmp-options is-stateless is-valid protocol source source-type tcp-options udp-options)
			nsg_rules=$(oci_capture_json oci_err "${profile}" network nsg rules list --nsg-id "${nsg_id}" "${query[@]}") || {
				[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
				err_ref+="unable to list rules for NSG ${nsg_name}: ${oci_err}"
				oci_err=''
				nsg_rules='[]'
			}

			nsg=$(jq \
				--argjson rules "${nsg_rules}" \
				'. + { rules: $rules }' <<<"${nsg}")

			nsg_arr+=("${nsg}")
		done < <(jq -c '.[]' <<<"${nsgs}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq \
		--argjson nsgs "$(to_json_array "${nsg_arr[@]}")" \
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
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }

	local -a query
	local -a public_ip_arr=()
	local public_ips public_ip oci_err
	while IFS= read -r comp_id; do
		mapfile -t query < <(query_array id assigned-entity-id assigned-entity-type \
			availability-domain compartment-id defined-tags display-name freeform-tags \
			ip-address lifecycle-state lifetime private-ip-id public-ip-pool-id scope)
		public_ips=$(oci_capture_json oci_err "${profile}" network public-ip list \
			--compartment-id "${comp_id}" --scope REGION "${query[@]}") || {
				[[ $oci_err == *$'\n' ]] || oci_err+=$'\n'
				err_ref+="unable to list public IPs for compartment ${comp_id}: ${oci_err}"
				oci_err=''
				continue
		}
		# shellcheck disable=SC2034
		mapfile -t -O "${#public_ip_arr[@]}" public_ip < <(jq -c '.[]' <<<"${public_ips}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary snapshot file: ${file_err}"
		return $?
	}

	if jq \
		--argjson public_ips "$(to_json_array "${public_ip_arr[@]}")" \
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
QUIET=false

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
		-q|--quiet)
			QUIET=true
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

# --- Configuration ---

err_msg=''
require_commands err_msg jq oci sed grep head cut tr date mktemp || fatal "${err_msg}" $?

# Auto-generate output filename if not specified
[[ -n "${OUT}" ]] || OUT=$(prefix_with_script_dir "snapshot-${PROFILE,,}-$(date +%Y%m%d%H%M%S).json")

# Validate OCI config exists
[[ -f "${CONFIG_FILE}" ]] || fatal "OCI config file not found: ${CONFIG_FILE}"

cleanup() {
	# Remove temp files created during this run only
	find "$(dirname "${OUT}")" -maxdepth 1 -name "$(basename "${OUT}").tmp.*" -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Main ---

log_progress "Initializing snapshot"
TENANCY_OCID=$(get_tenancy_ocid err_msg "${CONFIG_FILE}" "${PROFILE}") ||
	fatal "unable to find tenancy OCID: ${err_msg}" $?
# shellcheck disable=SC2153
init_snapshot err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" "${SCHEMA_VERSION}" ||
	fatal "unable to initialize snapshot: ${err_msg}" $?

log_progress "Extracting tenancy info"
extract_tenancy_info err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set tenancy info: ${err_msg}" $?

log_progress "Extracting tags"
extract_tags err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set tags: ${err_msg}" $?

log_progress "Extracting policies"
extract_policies err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set policies: ${err_msg}"

log_progress "Extracting users"
extract_users err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set users: ${err_msg}" $?

log_progress "Extracting dynamic groups"
extract_dynamic_groups err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set dynamic groups: ${err_msg}" $?

log_progress "Extracting identity domains"
extract_identity_domains err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set identity domains: ${err_msg}" $?

log_progress "Extracting compartments"
extract_compartments err_msg "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set compartments: ${err_msg}" $?

log_progress "Extracting virtual cloud networks"
extract_vcns err_msg "${OUT}" "${PROFILE}" || fatal "unable to set VCNs: ${err_msg}" $?

log_progress "Extracting dynamic routing gateways"
extract_drgs err_msg "${OUT}" "${PROFILE}" || fatal "unable to set networking: ${err_msg}" $?

log_progress "Extracting network security lists"
extract_nsgs err_msg "${OUT}" "${PROFILE}" || fatal "unable to set networking: ${err_msg}" $?

log_progress "Snapshot complete"
