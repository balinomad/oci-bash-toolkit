# OCI Bash Toolkit

[![License](https://img.shields.io/github/license/balinomad/oci-bash-toolkit)](./LICENSE)
[![Size](https://img.shields.io/github/languages/code-size/balinomad/oci-bash-toolkit)](https://github.com/balinomad/oci-bash-toolkit)
[![Bash Version](https://img.shields.io/badge/bash-4.3+-blue.svg)](https://www.gnu.org/software/bash/)

**OCI Bash Toolkit** is a Shell-based automation toolkit for Oracle Cloud Infrastructure (OCI).
Discover, transform, and provision OCI resources using bash scripts and OCI CLI.

**Perfect for:**
- Shell-first automation
- Transparent API calls
- Minimal dependencies
- Learning OCI structure
- Legacy enterprise environments

## Requirements

- **Bash 4.3+** (check: `bash --version`)
- **OCI CLI** ([install guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm))
- **jq 1.6+** ([install guide](https://stedolan.github.io/jq/))

### Installation

**Ubuntu/Debian:**

```bash
sudo apt-get install bash jq
pip3 install oci-cli
```

**Alpine (Docker):**
```bash
apk add bash jq
pip install oci-cli
```

**macOS:**
```bash
brew install bash jq oci-cli
```

## Tools

- [Tenancy Discovery & Clone](docs/tenancy-clone.md)
- [Instance Provisioning](docs/instance-provisioning.md)

## Legal

Oracle and OCI are trademarks of Oracle Corporation.
This is an independent project, not affiliated with or endorsed by Oracle.

[Installation](#installation) | [Contributing](#contributing) | [License](#license)
