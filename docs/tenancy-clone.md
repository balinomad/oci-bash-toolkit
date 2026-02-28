# Tenancy Cloning Workflow

The cloning workflow follows an ETL pattern: discover resources from a source
tenancy, transform the snapshot into a provisioning plan, then provision the plan
into a target tenancy.

**Implementation status:**

| Phase | Script | Status |
|-------|--------|--------|
| Discover | `tenancy/discover.sh` | Complete; usable standalone |
| Transform | `tenancy/transform.sh` | In progress; plan initialisation only |
| Provision | `tenancy/provision.sh` | Not yet implemented |

Discovery is fully functional and can be used independently to audit or document
a tenancy without any intention to clone. See [Standalone Discovery](#standalone-discovery).

## Standalone Discovery

Discover and snapshot all resources in a tenancy. No other phase is required.

```bash
tenancy/discover.sh -p prod -o snapshots/discovery-prod-$(date +%Y%m%d).json
```

The snapshot is a self-contained JSON file versioned with schema
`oci.tenancy.discovery.v1`. It captures IAM (compartments, users, groups, dynamic
groups, identity domains, tag namespaces, policies), network (VCNs with subnets,
route tables, security lists, and gateways; DRGs; NSGs; public IPs; load
balancers), object storage buckets, DNS zones, and certificates.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-p, --profile PROFILE` | `DEFAULT` or `$OCI_PROFILE` | OCI CLI profile |
| `-c, --config FILE` | `~/.oci/config` or `$OCI_CONFIG_FILE` | OCI config file |
| `-o, --output FILE` | auto-generated in script directory | Output snapshot path |
| `-t, --timeout SECS` | OCI CLI default | OCI CLI read timeout; `0` = OCI CLI default |
| `-q, --quiet` | — | Suppress info-level output |
| `-v, --verbose` | — | Enable debug-level output |

### Environment variables

| Variable | Equivalent flag |
|----------|----------------|
| `OCI_PROFILE` | `--profile` |
| `OCI_CONFIG_FILE` | `--config` |
| `OCI_SNAPSHOT_OUTPUT` | `--output` |

IAM resources are extracted concurrently; network resources are extracted
concurrently within their phase. DNS, certificates, and object storage buckets are
extracted sequentially after the network phase completes (they depend on
compartment data written during IAM extraction).

## Full Cloning Workflow (Partially Implemented)

The following documents the intended end-to-end workflow. Steps 2 and 3 are not
yet functional.

### 1. Discover

```bash
tenancy/discover.sh -p prod -o snapshots/discovery-prod-$(date +%Y%m%d).json
```

### 2. Transform _(in progress)_

Transform the snapshot into a provisioning plan. The script currently initialises
an empty plan file with schema `oci.tenancy.provision.v1`; the transformation
phases (filtering, key generation, dependency resolution, renaming, ordering) are
not yet implemented.

```bash
tenancy/transform.sh \
  --source "snapshots/discovery-prod-20250215.json" \
  --output "plans/provision-new-env.json" \
  --name-prefix "new-env-" \
  --exclude-path "/legacy"
```

### 3. Review and edit the plan

Manually review the generated plan and edit as needed before provisioning.

### 4. Provision _(not yet implemented)_

```bash
tenancy/provision.sh --plan plans/provision-new-env.json --target new-tenancy --dry-run
# Review output, then:
tenancy/provision.sh --plan plans/provision-new-env.json --target new-tenancy
```
