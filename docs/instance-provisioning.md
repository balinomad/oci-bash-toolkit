# Instance Provisioning

> **Status:** Written; not yet tested against a live tenancy.

`compute/instance-provision.sh` provisions an OCI compute instance from a JSON
launch-spec template. It retries across multiple availability domains (ADs) using
exponential backoff with decorrelated jitter until an instance is created or a
terminal condition stops the loop.

## Requirements

- Bash 4.3+
- OCI CLI configured with a valid profile
- jq 1.6+

The calling user or instance principal must hold `manage instances` permission in
the target compartment.

## Usage

```bash
compute/instance-provision.sh --spec FILE [OPTIONS]
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-s, --spec FILE` | _(required)_ | Instance launch spec JSON template |
| `-p, --profile PROFILE` | `DEFAULT` or `$OCI_PROFILE` | OCI CLI profile |
| `-c, --config FILE` | `~/.oci/config` or `$OCI_CONFIG_FILE` | OCI config file |
| `-o, --output FILE` | stdout | Write provisioned instance JSON here |
| `-t, --timeout SECS` | OCI CLI default | OCI CLI read timeout; `0` = OCI CLI default |
| `--dry-run` | — | Render per-AD specs and print commands; no API calls |
| `-q, --quiet` | — | Suppress info-level output |
| `-v, --verbose` | — | Enable debug-level output |
| `-h, --help` | — | Show usage |

### Environment variables

| Variable | Equivalent flag |
|----------|----------------|
| `OCI_PROFILE` | `--profile` |
| `OCI_CONFIG_FILE` | `--config` |

## Launch spec template

The spec is a standard OCI `compute instance launch` JSON payload. Use the
placeholder `{{AD_NUMBER}}` where the availability domain index should appear.
The script substitutes `1`, `2`, `3` (configurable) before each attempt.

### Minimal example

```json
{
  "compartmentId": "ocid1.compartment.oc1..example",
  "availabilityDomain": "AD-{{AD_NUMBER}}",
  "shape": "VM.Standard.E4.Flex",
  "shapeConfig": { "ocpus": 2, "memoryInGBs": 16 },
  "sourceDetails": {
    "sourceType": "image",
    "imageId": "ocid1.image.oc1..example"
  },
  "createVnicDetails": {
    "subnetId": "ocid1.subnet.oc1..example"
  },
  "displayName": "my-instance"
}
```

The full set of accepted fields matches the OCI CLI
`compute instance launch --from-json` schema.

## Retry behaviour

The script cycles through the configured ADs (default: 1, 2, 3) in sequence.
Each AD attempt is classified by error type:

| Error class | Behaviour |
|-------------|-----------|
| `CAPACITY` | Continue to next AD; no error count increment |
| `THROTTLE` | Continue; increment backoff exponent |
| `STATE` | Continue; no error count increment |
| `TIMEOUT` | Continue; increment total error count |
| `UNKNOWN` | Continue; increment total error count |
| `AUTH` | Fatal; exit immediately |
| `CONFIG` | Fatal; exit immediately |
| `OK` | Write instance JSON to output; exit 0 |

After each full cycle, the script sleeps for a duration computed as:

```
sleep = min(BASE_BACKOFF * 2^attempts + jitter, MAX_BACKOFF)
```

Backoff increases when any AD is throttled; it decreases by one step when a cycle
is clean.

### Operational tuning

The following constants are defined at the top of the script and can be edited
directly to adjust provisioning behaviour without adding CLI flags:

| Constant | Default | Description |
|----------|---------|-------------|
| `AD_NUMBERS` | `(1 2 3)` | ADs to cycle through |
| `MAX_CYCLES` | `5000` | Maximum retry cycles before giving up |
| `MAX_ERROR_CYCLES` | `3` | Consecutive error cycles before fatal exit |
| `BASE_BACKOFF` | `1` | Base backoff in seconds |
| `MAX_BACKOFF` | `300` | Maximum backoff in seconds |
| `MAX_BACKOFF_ATTEMPTS` | `9` | Exponent cap for backoff calculation |
| `DECORRELATED_JITTER` | `1` | Maximum random jitter added to backoff |
| `INTER_AD_MIN` | `1` | Minimum inter-AD delay in seconds |
| `INTER_AD_MAX` | `6` | Maximum inter-AD delay in seconds |

## Process locking

The script acquires an exclusive per-user process lock on startup using an atomic
`mkdir` mutex. Only one instance of `instance-provision.sh` may run per user at a
time. Stale locks from terminated processes are detected by PID liveness check and
removed automatically.

## Output

On success, the full OCI instance JSON is written to stdout (or `--output FILE`).
All log and progress output goes to stderr.

Exit codes: `0` success, `1` fatal error (auth, config, too many retries), `130`
SIGINT, `143` SIGTERM.

## Examples

```bash
# Dry run: inspect rendered spec for each AD without making API calls
compute/instance-provision.sh --spec specs/web-server.json --dry-run

# Provision with explicit profile and save result
compute/instance-provision.sh \
  --spec specs/web-server.json \
  --profile prod \
  --output snapshots/provisioned-instance.json

# Quiet mode, custom timeout
compute/instance-provision.sh \
  --spec specs/web-server.json \
  --timeout 120 \
  --quiet
```
