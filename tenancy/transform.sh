#!/usr/bin/env bash

# transform.sh - Transform a discovery snapshot into a provisioning plan
#
# Input:  discovery snapshot JSON (oci.tenancy.discovery.v1)
# Output: provisioning plan JSON  (oci.tenancy.provision.v1)
#
# Usage:
#   transform.sh --source <snapshot.json> [--output <plan.json>] [--force] [--quiet]
#
# If --output is omitted, the plan is written to <source-stem>.plan.json
# in the same directory as the source file.
# If the output file already exists, the script fails unless --force is given.

# Bash version check
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../lib" && pwd)/bash-version-check.sh"

set -euo pipefail

# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/../lib"

source "${LIB_DIR}/shell-utils.sh"
source "${LIB_DIR}/json-helpers.sh"

readonly INPUT_SCHEMA_VERSION="oci.tenancy.discovery.v1"
readonly OUTPUT_SCHEMA_VERSION="oci.tenancy.provision.v1"

# Print usage information
usage() {
	cat <<-EOF
	Usage: $(basename "$0") [OPTIONS]

	Transform a discovery snapshot into a provisioning plan.

	Required:
	  -s, --source FILE    Discovery snapshot file to transform

	Optional:
	  -o, --output FILE    Output plan file (default: <source-stem>.plan.json)
	  -f, --force          Overwrite output file if it already exists
	  -q, --quiet          Suppress progress output
	  -h, --help           Show this help message

	Output naming (when --output is omitted):
	  Input:  snapshots/snapshot-prod-20250215.json
	  Output: snapshots/snapshot-prod-20250215.plan.json
	EOF
	exit 0
}

# Derive the default output path from the source path
# Strips .json extension, appends .plan.json in the same directory.
# Args: source_file
# Output: derived output path to stdout
derive_output_path() {
	local source="${1:-}"
	local dir base stem

	dir="$(dirname -- "${source}")"
	base="$(basename -- "${source}")"
	stem="${base%.json}"

	printf '%s\n' "${dir}/${stem}.plan.json"
}

# Initialize an empty plan file with schema metadata
# Args: err_var_name out source schema
# Returns: 0 on success, 1 on failure, 2 on usage error
# Output: writes plan JSON to out
# Sets: error message to err_var_name
init_plan() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local source="${3:-}"
	local schema="${4:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]    || { err_ref="missing output file name"; return 2; }
	[[ -n "${source}" ]] || { err_ref="missing source file name"; return 2; }
	[[ -n "${schema}" ]] || { err_ref="missing schema version"; return 2; }

	local tmp_file file_err
	tmp_file=$(mktemp_sibling file_err "${out}") || {
		err_ref="failed to create temporary plan file: ${file_err}"
		return 1
	}

	if jq -n \
		--arg schema "${schema}" \
		--arg source "$(basename -- "${source}")" \
		--arg created_at "$(date -u -Iseconds)" \
		'{
			meta: {
				schema: $schema,
				source: $source,
				"created-at": $created_at
			}
		}' \
		> "${tmp_file}"; then
		mv -- "${tmp_file}" "${out}"
	else
		err_ref="failed to initialise plan file ${out}"
		rm -f -- "${tmp_file}"
		return 1
	fi
}

# Transform a discovery snapshot into a provisioning plan
# Args: err_var_name out source
# Returns: 0 on success, 1 on failure, 2 on usage error
# Output: writes transformed plan sections to out
# Sets: error message to err_var_name
transform() {
	local err_var_name="${1:-}"
	local out="${2:-}"
	local source="${3:-}"

	[[ -n "${err_var_name}" ]] || return 2
	local -n err_ref="${err_var_name}"
	err_ref=''

	[[ -n "${out}" ]]    || { err_ref="missing output file name"; return 2; }
	[[ -f "${out}" ]]    || { err_ref="output file ${out} not found"; return 1; }
	[[ -n "${source}" ]] || { err_ref="missing source file name"; return 2; }
	[[ -f "${source}" ]] || { err_ref="source file ${source} not found"; return 1; }

	# TODO: implement transformation phases
	# 1. Filter resources (apply include/exclude rules)
	# 2. Generate logical keys (comp:path, vcn:path/name)
	# 3. Resolve dependencies (build graph)
	# 4. Apply transformations (rename, remap tags)
	# 5. Sort by dependency order (phases)
	# 6. Remove discovery metadata (OCIDs, timestamps)
	# 7. Add provisioning metadata (dependencies, validations)
	:
}

# --- Parse Arguments ---

SOURCE=''
OUT=''
FORCE=false
QUIET=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		-s|--source)
			SOURCE="${2:-}"
			[[ -n "${SOURCE}" ]] || fatal "--source value cannot be empty"
			shift 2
			;;
		-o|--output)
			OUT="${2:-}"
			[[ -n "${OUT}" ]] || fatal "--output value cannot be empty"
			shift 2
			;;
		-f|--force)
			FORCE=true
			shift
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

# --- Validation ---

err_msg=''
require_commands err_msg jq || fatal "${err_msg}" $?

[[ -n "${SOURCE}" ]] || fatal "--source is required"
[[ -f "${SOURCE}" ]] || fatal "source file not found: ${SOURCE}"

validate_snapshot_schema err_msg "${SOURCE}" "${INPUT_SCHEMA_VERSION}" ||
	fatal "invalid source snapshot: ${err_msg}" $?

[[ -n "${OUT}" ]] || OUT="$(derive_output_path "${SOURCE}")"

if [[ -f "${OUT}" ]] && [[ "${FORCE}" != "true" ]]; then
	fatal "output file already exists: ${OUT} (use --force to overwrite)"
fi

cleanup() {
	find "$(dirname "${OUT}")" -maxdepth 1 \
		-name "$(basename "${OUT}").tmp.*" -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Main ---

log_progress "${QUIET}" "Initializing plan"
init_plan err_msg "${OUT}" "${SOURCE}" "${OUTPUT_SCHEMA_VERSION}" ||
	fatal "unable to initialize plan: ${err_msg}" $?

log_progress "${QUIET}" "Transforming snapshot"
transform err_msg "${OUT}" "${SOURCE}" ||
	fatal "unable to transform snapshot: ${err_msg}" $?

log_progress "${QUIET}" "Plan complete: ${OUT}"