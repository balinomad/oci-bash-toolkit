# OCI Bash Toolkit

[![License](https://img.shields.io/github/license/balinomad/oci-bash-toolkit)](./LICENSE)
[![Size](https://img.shields.io/github/languages/code-size/balinomad/oci-bash-toolkit)](https://github.com/balinomad/oci-bash-toolkit)
[![Bash Version](https://img.shields.io/badge/bash-4.3+-blue.svg)](https://www.gnu.org/software/bash/)

**OCI Bash Toolkit** is a shell-based automation toolkit for Oracle Cloud Infrastructure (OCI).
Discover, transform, and provision OCI resources using Bash scripts and the OCI CLI.

**Designed for:**
- Shell-first automation
- Transparent API calls
- Minimal dependencies
- Learning OCI resource structure
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

| Tool | Script | Status | Docs |
|------|--------|--------|------|
| Tenancy Discovery | `tenancy/discover.sh` | Ready | [tenancy-clone.md](docs/tenancy-clone.md) |
| Tenancy Transform | `tenancy/transform.sh` | In progress | [tenancy-clone.md](docs/tenancy-clone.md) |
| Tenancy Provision | `tenancy/provision.sh` | Not yet implemented | [tenancy-clone.md](docs/tenancy-clone.md) |
| Instance Provisioning | `compute/instance-provision.sh` | Written; not yet tested | [instance-provisioning.md](docs/instance-provisioning.md) |
| VCN Analyzer | `network/vcn-analyzer.sh` | Not yet implemented | — |

**Tenancy Discovery** is fully functional and can be used independently to audit
or document a tenancy. The full cloning workflow (transform + provision) is under
active development.

## Quick start

Discover all resources in a tenancy and save a snapshot:

```bash
tenancy/discover.sh -p prod -o snapshots/discovery-prod-$(date +%Y%m%d).json
```

See [Tenancy Cloning Workflow](docs/tenancy-clone.md) for details, including
standalone discovery usage and the planned end-to-end cloning workflow.

## Docker

Build and run the toolkit in an isolated container:

```bash
make build
make run
```

Or with docker-compose:

```bash
docker-compose up -d
docker-compose exec oci-toolkit /bin/bash
```

See [how-to-build.md](docs/how-to-build.md) for full Docker usage.

## Legal

Oracle and OCI are trademarks of Oracle Corporation.
This is an independent project, not affiliated with or endorsed by Oracle.

[Docker](docs/how-to-build.md) | [Tenancy Cloning](docs/tenancy-clone.md) | [Instance Provisioning](docs/instance-provisioning.md) | [License](LICENSE)
