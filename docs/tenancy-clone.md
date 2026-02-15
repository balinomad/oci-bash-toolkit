# Tenancy Cloning Workflow

The following ETL pattern can be used to clone a tenancy to a new tenancy.

## 1. Discover

Discover the resources of the tenancy and save them to a file.

```bash
./discover.sh -p prod -o snapshots/discovery-prod-$(date +%Y%m%d).json
```

## 2. Transform

Transform the snapshot into a format suitable for cloning.

```bash
./transform.sh \
  --source "snapshots/discovery-prod-20250215.json" \
  --output "plans/provision-new-env.json" \
  --name-prefix "new-env-" \
  --exclude-path "/legacy"
```

## 3. Review & Edit Plan

Manually review the plan and edit it if necessary.

## 4. Provision

Provision the new environment.

```bash
./provision.sh --plan plans/provision-new-env.json --target new-tenancy --dry-run
# Review output, then:
./provision.sh --plan plans/provision-new-env.json --target new-tenancy
```
