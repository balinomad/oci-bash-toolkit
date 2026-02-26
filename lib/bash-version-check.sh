#!/usr/bin/env bash

# bash-version-check.sh - Verify we are running in bash and it meets the minimum version requirement.
# Safe to source multiple times.

[ -n "${_BASH_VERSION_CHECKED:-}" ] && return 0
readonly _BASH_VERSION_CHECKED=1

# Check for bash (BASH_VERSION is unset in non-bash shells)
if [ -z "${BASH_VERSION}" ]; then
	echo "Error: This script requires bash" >&2
	exit 1
fi

# Minimum required version
readonly REQUIRED_BASH_MAJOR=4
readonly REQUIRED_BASH_MINOR=3

# Check major version
if [ "${BASH_VERSINFO[0]}" -lt "${REQUIRED_BASH_MAJOR}" ]; then
	echo "Error: Bash ${REQUIRED_BASH_MAJOR}.${REQUIRED_BASH_MINOR}+ required (you have ${BASH_VERSION})" >&2
	exit 1
fi

# Check minor version if major matches
if [ "${BASH_VERSINFO[0]}" -eq "${REQUIRED_BASH_MAJOR}" ] && [ "${BASH_VERSINFO[1]}" -lt "${REQUIRED_BASH_MINOR}" ]; then
	echo "Error: Bash ${REQUIRED_BASH_MAJOR}.${REQUIRED_BASH_MINOR}+ required (you have ${BASH_VERSION})" >&2
	exit 1
fi

# Version check passed