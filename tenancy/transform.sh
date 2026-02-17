#!/usr/bin/env bash

# transform.sh - Convert discovery JSON to provision JSON

# Input: discovery.json (pure capture)
# Output: provision.json (ready to execute)

# Bash version check
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../lib" && pwd)/bash-version-check.sh"

set -euo pipefail

# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/../lib"

source "${LIB_DIR}/json-helpers.sh"

# shellcheck disable=SC2034
readonly SCHEMA_VERSION="oci.tenancy.discovery.v1"

transform() {
  local discovery="$1"
  local provision="$2"

  # 1. Filter resources (apply include/exclude rules)
  # 2. Generate logical keys (comp:path, vcn:path/name)
  # 3. Resolve dependencies (build graph)
  # 4. Apply transformations (rename, remap tags)
  # 5. Sort by dependency order (phases)
  # 6. Remove discovery metadata (OCIDs, timestamps)
  # 7. Add provisioning metadata (dependencies, validations)
}

err_msg=''
require_commands err_msg jq || fatal "${err_msg}" $?

# Validate input schema
validate_snapshot_schema err_msg "${INPUT_FILE}" "${SCHEMA_VERSION}" ||
	fatal "invalid snapshot: ${err_msg}" $?
