#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# Docker entrypoint for OCI Bash Toolkit
# Handles OCI CLI configuration and credential validation
# ============================================================================

readonly OCI_CONFIG_DIR="${HOME}/.oci"
readonly OCI_CONFIG_FILE="${OCI_CONFIG_DIR}/config"

# Colors for output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m' # No Color

log_info() {
	printf "%b[INFO]%b %s\n" "${GREEN}" "${NC}" "$*" >&2
}

log_warn() {
	printf "%b[WARN]%b %s\n" "${YELLOW}" "${NC}" "$*" >&2
}

log_error() {
	printf "%b[ERROR]%b %s\n" "${RED}" "${NC}" "$*" >&2
}

# Validate OCI CLI configuration
validate_oci_config() {
	# Check for instance principal (running on OCI compute)
	if [[ -n "${OCI_CLI_AUTH:-}" ]] && [[ "${OCI_CLI_AUTH}" == "instance_principal" ]]; then
		log_info "Using instance principal authentication"
		return 0
	fi

	# Check for resource principal (running in OCI Functions/Container Instances)
	if [[ -n "${OCI_CLI_AUTH:-}" ]] && [[ "${OCI_CLI_AUTH}" == "resource_principal" ]]; then
		log_info "Using resource principal authentication"
		return 0
	fi

	# Check for config file
	if [[ -f "${OCI_CONFIG_FILE}" ]]; then
		log_info "Found OCI config at ${OCI_CONFIG_FILE}"

		# Validate config file permissions (should be readable only by user)
		if [[ "$(stat -c %a "${OCI_CONFIG_FILE}" 2>/dev/null || stat -f %A "${OCI_CONFIG_FILE}" 2>/dev/null)" != "600" ]]; then
			log_warn "OCI config file permissions are not 600, this may cause issues"
		fi

		# Test OCI CLI connectivity
		if ! oci iam region list --output json > /dev/null 2>&1; then
			log_error "OCI CLI authentication failed. Check your config file and credentials."
			return 1
		fi

		log_info "OCI CLI authentication successful"
		return 0
	fi

	log_error "No OCI credentials found. Mount config file at ${OCI_CONFIG_FILE} or set OCI_CLI_AUTH environment variable."
	log_error "Example: docker run -v \${HOME}/.oci:/home/ociuser/.oci:ro ..."
	return 1
}

# Main entrypoint logic
main() {
	log_info "OCI Bash Toolkit - Starting"
	log_info "Bash version: $(bash --version | head -n1)"
	log_info "jq version: $(jq --version)"
	log_info "OCI CLI version: $(oci --version 2>&1)"

	# Validate OCI configuration (non-blocking warning)
	if ! validate_oci_config; then
		log_warn "Proceeding without validated OCI credentials"
		log_warn "Some toolkit operations will fail without proper authentication"
	fi

	# If no arguments, start interactive shell
	if [[ $# -eq 0 ]]; then
		log_info "Starting interactive shell"
		exec /bin/bash
	fi

	# Execute provided command
	log_info "Executing: $*"
	exec "$@"
}

main "$@"