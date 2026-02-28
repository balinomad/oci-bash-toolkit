#!/usr/bin/env bash

# discover.sh - Discover OCI resources and generate a snapshot

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

# Print usage information
usage() {
	cat <<-EOF
	Usage: $(basename "$0") [OPTIONS]

	Options:
	  -p, --profile PROFILE       OCI CLI profile (default: DEFAULT)
	  -c, --config FILE           OCI config file (default: ~/.oci/config)
	  -o, --output FILE           Output snapshot file (default: auto-generated)
	  -t, --timeout SECS          OCI CLI read timeout in seconds; 0 = OCI CLI default
	  -q, --quiet                 Suppress progress output
	  -v, --verbose               Verbose progress output
	  -h, --help                  Show this help message

	Environment variables:
	  OCI_PROFILE                 Same as --profile
	  OCI_CONFIG_FILE             Same as --config
	  OCI_SNAPSHOT_OUTPUT         Same as --output
	EOF
	exit 0
}

# --- Script-specific Utilities ---

# Prefix with the script's directory if only a filename is given
prefix_with_script_dir() {
	local file="${1:-}"
	[[ "${file}" == */* ]] && printf '%s\n' "${file}" || printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${file}"
}

# --- Snapshot Utilities ---

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
				"public-ips": [],
				"load-balancers": []
			},
			storage: {
				buckets: []
			},
			certificates: {
				"ssl-certificates": []
			},
			dns: {
				zones: []
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local tenancy_info oci_err
	mapfile -t query_args < <(query id name home-region-key description defined-tags freeform-tags)
	tenancy_info=$(oci_capture_json oci_err "${profile}" iam tenancy get --tenancy-id "${tenancy_ocid}" "${query_args[@]}") || {
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	# Cache ignored namespaces list
	local ignored_ns
	ignored_ns=$(jq -c '.meta.ignored."tag-namespaces"' "${out}")

	local -a query_args
	local oci_err

	# Get tag namespaces
	local namespaces
	mapfile -t query_args < <(query_array id name description is-retired defined-tags freeform-tags lifecycle-state)
	namespaces=$(oci_capture_json oci_err "${profile}" iam tag-namespace list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
		err_ref="failed to get tag namespaces: ${oci_err}"
		return $?
	}

	# Populate tag namespaces
	local -a ns_arr=()
	local ns
	while IFS= read -r ns; do
		local ns_name ns_id
		ns_name=$(jq -r '.name' <<<"${ns}")
		ns_id=$(jq -r '.id' <<<"${ns}")
		[[ -n "${ns_id}" ]] || {
			# Continue on individual resource errors to capture partial snapshot
			err_ref="$(append_line "${err_ref}" "unable to get namespace id for ${ns_name:-<unknown>}")"
			continue
		}

		ns=$(jq \
			--arg name "${ns_name}" \
			--argjson ignored "${ignored_ns}" \
			'. + { ignored: ($ignored | index($name)) != null }' <<<"${ns}")

		local tag_names
		mapfile -t query_args < <(query_array name)
		tag_names=$(oci_capture_json oci_err "${profile}" iam tag list --tag-namespace-id "${ns_id}" "${query_args[@]}") || {
			err_ref="$(append_line "${err_ref}" "unable to list tag names for namespace ${ns_name}: ${oci_err:-unknown error}")"
			oci_err=''
			continue
		}

		# Get all tags
		local -a ns_tags=()
		local tag_name
		while IFS= read -r tag_name; do
			local tag
			mapfile -t query_args < <(query id name description is-cost-tracking is-retired defined-tags freeform-tags lifecycle-state validator)
			tag=$(oci_capture_json oci_err "${profile}" iam tag get --tag-namespace-id "${ns_id}" --tag-name "${tag_name}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to get tag definition for tag ${ns_name}.${tag_name}: ${oci_err:-unknown error}")"
				oci_err=''
				continue
			}

			ns_tags+=("${tag}")
		done < <(jq -r '.[].name' <<<"${tag_names}")

		ns=$(jq \
			--argjson tags "$(to_json_array "${ns_tags[@]}")" \
			'. + { "tag-definitions": $tags }' <<<"${ns}")

		ns_arr+=("${ns}")
	done < <(jq -c '.[]' <<<"${namespaces}")

	# Get tag defaults
	local defaults
	mapfile -t query_args < <(query_array id value tag-namespace-id tag-definition-id tag-definition-name is-required lifecycle-state locks)
	defaults=$(oci_capture_json oci_err "${profile}" iam tag-default list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
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

	local writer_err rc=0
	[[ -z "${err_ref}" ]] || rc=1
	write_section writer_err "${out}" '.iam."tag-namespaces"' "${ns_list}" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "${writer_err:-unknown error}")"
	}

	return ${rc}
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	# Get policies
	local -a query_args
	local policies oci_err
	mapfile -t query_args < <(query_array id name description statements defined-tags freeform-tags inactive-status lifecycle-state)
	policies=$(oci_capture_json oci_err "${profile}" iam policy list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
		err_ref="failed to get policies: ${oci_err}"
		return $?
	}

	write_section "${err_var_name}" "${out}" '.iam.policies' "${policies}" || return $?
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local oci_err

	# Get users
	local users
	mapfile -t query_args < <(query_array id name description capabilities compartment-id external-identifier defined-tags \
		freeform-tags inactive-status lifecycle-state)
	users=$(oci_capture_json oci_err "${profile}" iam user list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
		err_ref="failed to get users: ${oci_err}"
		return $?
	}

	# Get groups
	local groups
	mapfile -t query_args < <(query_array id name description compartment-id defined-tags freeform-tags inactive-status lifecycle-state)
	groups=$(oci_capture_json oci_err "${profile}" iam group list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
		err_ref="failed to get groups: ${oci_err}"
		return $?
	}

	# Get additional information for each user
	local -a user_arr=()
	local user
	while IFS= read -r user; do
		local user_name user_id
		user_name=$(jq -r '.name' <<<"${user}")
		user_id=$(jq -r '.id' <<<"${user}")
		[[ -n "${user_id}" ]] || {
			err_ref="$(append_line "${err_ref}" "unable to get user id for ${user_name:-<unknown>}")"
			continue
		}

		# Get group memberships
		local memberships
		mapfile -t query_args < <(query_array id name)
		memberships=$(oci_capture_json oci_err "${profile}" \
			iam user list-groups --compartment-id "${tenancy_ocid}" --user-id "${user_id}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to get group memberships for user ${user_name}: ${oci_err:-unknown error}")"
				oci_err=''
				memberships='[]'
		}

		# Get API keys
		local api_keys
		mapfile -t query_args < <(query_array key-id key-value fingerprint inactive-status lifecycle-state)
		api_keys=$(oci_capture_json oci_err "${profile}" \
			iam user api-key list --user-id "${user_id}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to get API keys for user ${user_name}: ${oci_err:-unknown error}")"
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

	local writer_err rc=0
	[[ -z "${err_ref}" ]] || rc=1
	write_section writer_err "${out}" '.iam.groups' "${groups}" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write user groups: ${writer_err:-unknown error}")"
	}
	write_section writer_err "${out}" '.iam.users' "$(to_json_array "${user_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write users: ${writer_err:-unknown error}")"
	}

	return ${rc}
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	# Get dynamic groups
	local -a query_args
	local dynamic_groups oci_err
	mapfile -t query_args < <(query_array)
	dynamic_groups=$(oci_capture_json oci_err "${profile}" iam dynamic-group list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
		err_ref="failed to get dynamic groups: ${oci_err}"
		return $?
	}

	write_section "${err_var_name}" "${out}" '.iam."dynamic-groups"' "${dynamic_groups}" || return $?
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local domains oci_err
	mapfile -t query_args < <(query_array id display-name description type url defined-tags freeform-tags home-region home-region-url \
		is-hidden-on-login license-type lifecycle-details lifecycle-state replica-regions)
	domains=$(oci_capture_json oci_err "${profile}" iam domain list --compartment-id "${tenancy_ocid}" "${query_args[@]}") || {
		err_ref="failed to get identity domains: ${oci_err}"
		return $?
	}

	write_section "${err_var_name}" "${out}" '.iam."identity-domains"' "${domains}" || return $?
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
	[[ -n "${profile}" ]]      || { err_ref="missing profile name"; return 2; }
	[[ -n "${tenancy_ocid}" ]] || { err_ref="missing tenancy OCID"; return 2; }
	[[ -f "${out}" ]]          || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local compartments oci_err
	mapfile -t query_args < <(query_array id name description compartment-id defined-tags freeform-tags inactive-status is-accessible lifecycle-state)
	compartments=$(oci_capture_json oci_err "${profile}" iam compartment list --compartment-id "${tenancy_ocid}" \
		--access-level ANY --compartment-id-in-subtree true "${query_args[@]}") || {
			err_ref="failed to get compartments: ${oci_err}"
			return $?
	}

	write_section "${err_var_name}" "${out}" '.iam.compartments' "${compartments}" || return $?
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
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	# Get VCNs for each compartment
	local -a query_args
	local -a vcn_arr=()
	local oci_err
	while IFS= read -r comp_id; do
		local vcns
		mapfile -t query_args < <(query_array id compartment-id cidr-block cidr-blocks \
			default-dhcp-options-id default-route-table-id default-security-list-id \
			defined-tags display-name dns-label freeform-tags lifecycle-state vcn-domain-name)
		vcns=$(oci_capture_json oci_err "${profile}" network vcn list --compartment-id "${comp_id}" "${query_args[@]}") || {
			err_ref="$(append_line "${err_ref}" "unable to list VCNs for compartment ${comp_id}: ${oci_err:-unknown error}")"
			oci_err=''
			continue
		}

		local vcn
		while IFS= read -r vcn; do
			local vcn_name vcn_id vcn_comp
			vcn_name=$(jq -r '."display-name"' <<<"${vcn}")
			vcn_id=$(jq -r '.id' <<<"${vcn}")
			vcn_comp=$(jq -r '."compartment-id"' <<<"${vcn}")

			# Get subnets
			local subnets
			mapfile -t query_args < <(query_array id availability-domain cidr-block compartment-id \
				defined-tags dhcp-options-id display-name dns-label freeform-tags lifecycle-state \
				prohibit-internet-ingress prohibit-public-ip-on-vnic route-table-id \
				security-list-ids subnet-domain-name vcn-id)
			subnets=$(oci_capture_json oci_err "${profile}" network subnet list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list subnets for VCN ${vcn_name}: ${oci_err:-unknown error}")"
					oci_err=''
					subnets='[]'
			}

			# Get route tables
			local route_tables
			mapfile -t query_args < <(query_array id compartment-id defined-tags display-name \
				freeform-tags lifecycle-state route-rules vcn-id)
			route_tables=$(oci_capture_json oci_err "${profile}" network route-table list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list route tables for VCN ${vcn_name}: ${oci_err:-unknown error}")"
					oci_err=''
					route_tables='[]'
			}

			# Get security lists
			local security_lists
			mapfile -t query_args < <(query_array id compartment-id defined-tags display-name \
				egress-security-rules freeform-tags ingress-security-rules lifecycle-state vcn-id)
			security_lists=$(oci_capture_json oci_err "${profile}" network security-list list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list security lists for VCN ${vcn_name}: ${oci_err:-unknown error}")"
					oci_err=''
					security_lists='[]'
			}

			# Get internet gateways
			local igws
			mapfile -t query_args < <(query_array id compartment-id defined-tags display-name \
				freeform-tags is-enabled lifecycle-state vcn-id)
			igws=$(oci_capture_json oci_err "${profile}" network internet-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list internet gateways for VCN ${vcn_name}: ${oci_err:-unknown error}")"
					oci_err=''
					igws='[]'
			}

			# Get NAT gateways
			local nat_gws
			mapfile -t query_args < <(query_array id block-traffic compartment-id defined-tags \
				display-name freeform-tags lifecycle-state nat-ip public-ip-id vcn-id)
			nat_gws=$(oci_capture_json oci_err "${profile}" network nat-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list NAT gateways for VCN ${vcn_name}: ${oci_err:-unknown error}")"
					oci_err=''
					nat_gws='[]'
			}

			# Get service gateways
			local service_gws
			mapfile -t query_args < <(query_array id block-traffic compartment-id defined-tags \
				display-name freeform-tags lifecycle-state route-table-id services vcn-id)
			service_gws=$(oci_capture_json oci_err "${profile}" network service-gateway list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list service gateways for VCN ${vcn_name}: ${oci_err:-unknown error}")"
					oci_err=''
					service_gws='[]'
			}

			# Get DRG attachments
			local drg_attachments
			mapfile -t query_args < <(query_array id compartment-id defined-tags display-name drg-id \
				drg-route-table-id freeform-tags lifecycle-state network-details route-table-id vcn-id)
			drg_attachments=$(oci_capture_json oci_err "${profile}" network drg-attachment list \
				--compartment-id "${vcn_comp}" --vcn-id "${vcn_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list DRG attachments for VCN ${vcn_name}: ${oci_err:-unknown error}")"
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

	local writer_err rc=0
	write_section writer_err "${out}" '.network.vcns' "$(to_json_array "${vcn_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write vcn section: ${writer_err:-unknown error}")"
	}

	return ${rc}
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
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local -a drg_arr=()
	local drgs oci_err
	while IFS= read -r comp_id; do
		mapfile -t query_args < <(query_array id compartment-id default-drg-route-tables \
			default-export-drg-route-distribution-id defined-tags display-name freeform-tags lifecycle-state)
		drgs=$(oci_capture_json oci_err "${profile}" network drg list --compartment-id "${comp_id}" "${query_args[@]}") || {
			err_ref="$(append_line "${err_ref}" "unable to list DRGs for compartment ${comp_id}: ${oci_err:-unknown error}")"
			oci_err=''
			continue
		}
		mapfile -t -O "${#drg_arr[@]}" drg_arr < <(jq -c '.[]' <<<"${drgs}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.network.drgs' "$(to_json_array "${drg_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write drg section: ${writer_err:-unknown error}")"
	}

	return ${rc}
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
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local -a nsg_arr=()
	local oci_err
	while IFS= read -r comp_id; do
		local nsgs
		mapfile -t query_args < <(query_array id compartment-id defined-tags display-name \
			freeform-tags lifecycle-state vcn-id)
		nsgs=$(oci_capture_json oci_err "${profile}" network nsg list --compartment-id "${comp_id}" "${query_args[@]}") || {
			err_ref="$(append_line "${err_ref}" "unable to list NSGs for compartment ${comp_id}: ${oci_err:-unknown error}")"
			oci_err=''
			continue
		}

		local nsg
		while IFS= read -r nsg; do
			local nsg_name nsg_id
			nsg_name=$(jq -r '."display-name"' <<<"${nsg}")
			nsg_id=$(jq -r '.id' <<<"${nsg}")

			# Get NSG rules
			local nsg_rules
			mapfile -t query_args < <(query_array id description destination destination-type direction \
				icmp-options is-stateless is-valid protocol source source-type tcp-options udp-options)
			nsg_rules=$(oci_capture_json oci_err "${profile}" network nsg rules list --nsg-id "${nsg_id}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to list rules for NSG ${nsg_name}: ${oci_err:-unknown error}")"
				oci_err=''
				nsg_rules='[]'
			}

			local nsg
			nsg=$(jq \
				--argjson rules "${nsg_rules}" \
				'. + { rules: $rules }' <<<"${nsg}")

			nsg_arr+=("${nsg}")
		done < <(jq -c '.[]' <<<"${nsgs}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.network.nsgs' "$(to_json_array "${nsg_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write nsg section: ${writer_err:-unknown error}")"
	}

	return ${rc}
}

# Get public IP addresses
extract_public_ips() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local -a public_ip_arr=()
	local public_ips oci_err
	while IFS= read -r comp_id; do
		mapfile -t query_args < <(query_array id assigned-entity-id assigned-entity-type \
			availability-domain compartment-id defined-tags display-name freeform-tags \
			ip-address lifecycle-state lifetime private-ip-id public-ip-pool-id scope)
		public_ips=$(oci_capture_json oci_err "${profile}" network public-ip list \
			--compartment-id "${comp_id}" --scope REGION "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to list public IPs for compartment ${comp_id}: ${oci_err:-unknown error}")"
				oci_err=''
				continue
		}

		mapfile -t -O "${#public_ip_arr[@]}" public_ip_arr < <(jq -c '.[]' <<<"${public_ips}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.network."public-ips"' "$(to_json_array "${public_ip_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write public ip section: ${writer_err:-unknown error}")"
	}

	return ${rc}
}

# Get load balancers
extract_load_balancers() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local -a lb_arr=()
	local oci_err
	while IFS= read -r comp_id; do
		local lbs
		mapfile -t query_args < <(query_array id compartment-id display-name shape-name \
			ip-addresses is-private defined-tags freeform-tags lifecycle-state \
			subnet-ids network-security-group-ids)
		lbs=$(oci_capture_json oci_err "${profile}" lb load-balancer list \
			--compartment-id "${comp_id}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to list load balancers for compartment ${comp_id}: ${oci_err:-unknown error}")"
				oci_err=''
				continue
		}

		local lb
		while IFS= read -r lb; do
			local lb_name lb_id
			lb_name=$(jq -r '."display-name"' <<<"${lb}")
			lb_id=$(jq -r '.id' <<<"${lb}")

			# Get backend sets
			local backend_sets
			mapfile -t query_args < <(query_array)
			backend_sets=$(oci_capture_json oci_err "${profile}" lb backend-set list \
				--load-balancer-id "${lb_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list backend sets for LB ${lb_name}: ${oci_err:-unknown error}")"
					oci_err=''
					backend_sets='[]'
			}

			# Get listeners
			local listeners
			mapfile -t query_args < <(query_array)
			listeners=$(oci_capture_json oci_err "${profile}" lb listener list \
				--load-balancer-id "${lb_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list listeners for LB ${lb_name}: ${oci_err:-unknown error}")"
					oci_err=''
					listeners='[]'
			}

			# Get certificates
			local certificates
			mapfile -t query_args < <(query_array)
			certificates=$(oci_capture_json oci_err "${profile}" lb certificate list \
				--load-balancer-id "${lb_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list certificates for LB ${lb_name}: ${oci_err:-unknown error}")"
					oci_err=''
					certificates='[]'
			}

			# Get hostnames
			local hostnames
			mapfile -t query_args < <(query_array)
			hostnames=$(oci_capture_json oci_err "${profile}" lb hostname list \
				--load-balancer-id "${lb_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list hostnames for LB ${lb_name}: ${oci_err:-unknown error}")"
					oci_err=''
					hostnames='[]'
			}

			# Get path route sets
			local path_routes
			mapfile -t query_args < <(query_array)
			path_routes=$(oci_capture_json oci_err "${profile}" lb path-route-set list \
				--load-balancer-id "${lb_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list path routes for LB ${lb_name}: ${oci_err:-unknown error}")"
					oci_err=''
					path_routes='[]'
			}

			# Get rule sets
			local rule_sets
			mapfile -t query_args < <(query_array)
			rule_sets=$(oci_capture_json oci_err "${profile}" lb rule-set list \
				--load-balancer-id "${lb_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to list rule sets for LB ${lb_name}: ${oci_err:-unknown error}")"
					oci_err=''
					rule_sets='[]'
			}

			lb=$(jq \
				--argjson backend_sets "${backend_sets}" \
				--argjson listeners "${listeners}" \
				--argjson certificates "${certificates}" \
				--argjson hostnames "${hostnames}" \
				--argjson path_routes "${path_routes}" \
				--argjson rule_sets "${rule_sets}" \
				'. + {
					"backend-sets": $backend_sets,
					listeners: $listeners,
					certificates: $certificates,
					hostnames: $hostnames,
					"path-route-sets": $path_routes,
					"rule-sets": $rule_sets
				}' <<<"${lb}")

			lb_arr+=("${lb}")
		done < <(jq -c '.[]' <<<"${lbs}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.network."load-balancers"' "$(to_json_array "${lb_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write load balancers: ${writer_err:-unknown error}")"
	}

	return ${rc}
}

# Get DNS zones
extract_dns_zones() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local -a zone_arr=()
	local oci_err
	while IFS= read -r comp_id; do
		local zones
		mapfile -t query_args < <(query_array id name zone-type compartment-id \
			defined-tags freeform-tags lifecycle-state scope self serial version)
		zones=$(oci_capture_json oci_err "${profile}" dns zone list \
			--compartment-id "${comp_id}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to list DNS zones for compartment ${comp_id}: ${oci_err:-unknown error}")"
				oci_err=''
				continue
		}

		while IFS= read -r zone; do
			local zone_name zone_id
			zone_name=$(jq -r '.name' <<<"${zone}")
			zone_id=$(jq -r '.id' <<<"${zone}")

			# Get zone records
			local records
			mapfile -t query_args < <(query_array domain rdata rtype ttl)
			records=$(oci_capture_json oci_err "${profile}" dns record zone get \
				--zone-name-or-id "${zone_id}" "${query_args[@]}") || {
					err_ref="$(append_line "${err_ref}" "unable to get records for DNS zone ${zone_name}: ${oci_err:-unknown error}")"
					oci_err=''
					records='{"items":[]}'
			}

			local zone
			zone=$(jq \
				--argjson records "${records}" \
				'. + { records: $records.items }' <<<"${zone}")

			zone_arr+=("${zone}")
		done < <(jq -c '.[]' <<<"${zones}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.dns.zones' "$(to_json_array "${zone_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write DNS zones: ${writer_err:-unknown error}")"
	}

	return ${rc}
}

# Get certificates
extract_certificates() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	local -a query_args
	local -a cert_arr=()
	local certs oci_err
	while IFS= read -r comp_id; do
		mapfile -t query_args < <(query_array id name description compartment-id \
			certificate-profile-type defined-tags freeform-tags lifecycle-state \
			issuer-certificate-authority-id config-type subject current-version \
			time-created)
		certs=$(oci_capture_json oci_err "${profile}" certs-mgmt certificate list \
			--compartment-id "${comp_id}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to list certificates for compartment ${comp_id}: ${oci_err:-unknown error}")"
				oci_err=''
				continue
		}

		mapfile -t -O "${#cert_arr[@]}" cert_arr < <(jq -c '.[]' <<<"${certs}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.certificates."ssl-certificates"' "$(to_json_array "${cert_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write certificates: ${writer_err:-unknown error}")"
	}

	return ${rc}
}

# Get object storage buckets
extract_buckets() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local profile="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]     || { err_ref="missing output file name"; return 2; }
	[[ -n "${profile}" ]] || { err_ref="missing profile name"; return 2; }
	[[ -f "${out}" ]]     || { err_ref="output file ${out} not found"; return 1; }

	# Get object storage namespace
	local namespace oci_err
	namespace=$(oci_capture_json oci_err "${profile}" os ns get --query data) || {
		err_ref="unable to get object storage namespace: ${oci_err}"
		return $?
	}
	namespace=$(jq -r '.' <<<"${namespace}")

	local -a query_args
	local -a bucket_arr=()
	while IFS= read -r comp_id; do
		local buckets
		mapfile -t query_args < <(query_array name compartment-id namespace \
			created-by time-created defined-tags freeform-tags)
		buckets=$(oci_capture_json oci_err "${profile}" os bucket list \
			--compartment-id "${comp_id}" --namespace-name "${namespace}" "${query_args[@]}") || {
				err_ref="$(append_line "${err_ref}" "unable to list buckets for compartment ${comp_id}: ${oci_err:-unknown error}")"
				oci_err=''
				continue
		}

		local bucket
		while IFS= read -r bucket; do
			local bucket_name
			bucket_name=$(jq -r '.name' <<<"${bucket}")

			# Get lifecycle policy
			mapfile -t query_args < <(query)
			lifecycle=$(oci_capture_json oci_err "${profile}" os object-lifecycle-policy get \
				--bucket-name "${bucket_name}" --namespace-name "${namespace}" "${query_args[@]}") || {
					lifecycle='null'
			}

			# Get replication policy
			mapfile -t query_args < <(query_array)
			replication=$(oci_capture_json oci_err "${profile}" os replication-policy list \
				--bucket-name "${bucket_name}" --namespace-name "${namespace}" "${query_args[@]}") || {
					replication='[]'
			}

			bucket=$(jq \
				--argjson lifecycle "${lifecycle}" \
				--argjson replication "${replication}" \
				'. + {
					"lifecycle-policy": $lifecycle,
					"replication-policies": $replication
				}' <<<"${bucket}")

			bucket_arr+=("${bucket}")
		done < <(jq -c '.[]' <<<"${buckets}")
	done <<<"$(jq -r '[.iam.tenancy.id, .iam.compartments[].id] | .[]' "${out}")"

	local writer_err rc=0
	write_section writer_err "${out}" '.storage.buckets' "$(to_json_array "${bucket_arr[@]}")" || {
		rc=1
		err_ref="$(append_line "${err_ref}" "failed to write object storage buckets: ${writer_err:-unknown error}")"
	}

	return ${rc}
}

# --- Parse Arguments ---

# Start with defaults
declare PROFILE="${OCI_PROFILE:-DEFAULT}"
declare CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
declare OUT="${OCI_SNAPSHOT_OUTPUT:-}"
declare ERR_MSG=''

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
		-t|--timeout)
			OCI_READ_TIMEOUT="${2:-}"
			[[ "${OCI_READ_TIMEOUT}" =~ ^[0-9]+$ ]] \
				|| fatal "--timeout must be a non-negative integer; got: '${OCI_READ_TIMEOUT}'"
			shift 2
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

# --- Configuration ---

require_commands ERR_MSG jq oci sed grep head cut tr date mktemp || fatal "${ERR_MSG}" $?

# Auto-generate output filename if not specified
[[ -n "${OUT}" ]] || OUT=$(prefix_with_script_dir "snapshot-${PROFILE,,}-$(date +%Y%m%d%H%M%S).json")

# Validate OCI config exists
[[ -f "${CONFIG_FILE}" ]] || fatal "OCI config file not found: ${CONFIG_FILE}"

cleanup() {
	find "$(dirname "${OUT}")" -maxdepth 1 \
		\( -name "$(basename "${OUT}").tmp.*" \
		-o -name "$(basename "${OUT}").lock" \) \
		-delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Main ---

declare -A JOBS
declare TENANCY_OCID=''

log_info "Initializing snapshot"
TENANCY_OCID=$(get_tenancy_ocid ERR_MSG "${CONFIG_FILE}" "${PROFILE}") ||
	fatal "unable to find tenancy OCID: ${ERR_MSG}" $?

init_snapshot ERR_MSG "${OUT}" "${PROFILE}" "${TENANCY_OCID}" "${SCHEMA_VERSION}" ||
	fatal "unable to initialize snapshot: ${ERR_MSG}" $?

log_info "Extracting tenancy info"
extract_tenancy_info ERR_MSG "${OUT}" "${PROFILE}" "${TENANCY_OCID}" ||
	fatal "unable to set tenancy info: ${ERR_MSG}" $?

# --- IAM ---

log_info "Extracting IAM objects"

# Define IAM jobs
JOBS=()
add_job JOBS tags               extract_tags             "${OUT}" "${PROFILE}" "${TENANCY_OCID}"
add_job JOBS policies           extract_policies         "${OUT}" "${PROFILE}" "${TENANCY_OCID}"
add_job JOBS users              extract_users            "${OUT}" "${PROFILE}" "${TENANCY_OCID}"
add_job JOBS "dynamic groups"   extract_dynamic_groups   "${OUT}" "${PROFILE}" "${TENANCY_OCID}"
add_job JOBS "identity domains" extract_identity_domains "${OUT}" "${PROFILE}" "${TENANCY_OCID}"
add_job JOBS "compartments"     extract_compartments     "${OUT}" "${PROFILE}" "${TENANCY_OCID}"

# Run IAM jobs concurrently
run_jobs JOBS || fatal "unable to extract IAM objects" $?

# --- Network ---

log_info "Extracting network objects"

# Define network jobs
# shellcheck disable=SC2034
JOBS=()
add_job JOBS "virtual cloud networks"   extract_vcns           "${OUT}" "${PROFILE}"
add_job JOBS "dynamic routing gateways" extract_drgs           "${OUT}" "${PROFILE}"
add_job JOBS "network security lists"   extract_nsgs           "${OUT}" "${PROFILE}"
add_job JOBS "load balancers"           extract_load_balancers "${OUT}" "${PROFILE}"
add_job JOBS "public IP addresses"      extract_public_ips     "${OUT}" "${PROFILE}"

# Run network jobs concurrently
run_jobs JOBS || fatal "unable to extract network objects" $?

log_info "Extracting DNS zones"
extract_dns_zones ERR_MSG "${OUT}" "${PROFILE}" || fatal "unable to set DNS zones: ${ERR_MSG}" $?

log_info "Extracting certificates"
extract_certificates ERR_MSG "${OUT}" "${PROFILE}" || fatal "unable to set certificates: ${ERR_MSG}" $?

log_info "Extracting object storage buckets"
extract_buckets ERR_MSG "${OUT}" "${PROFILE}" || fatal "unable to set object storage buckets: ${ERR_MSG}" $?

log_info "Snapshot complete"
