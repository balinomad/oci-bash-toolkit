# Build OCI Bash Toolkit

## Build image

```bash
make build
`

## Run interactively

```bash
make run
```

## Run specific discovery script

```bash
make run-script SCRIPT="tenancy/discover.sh -p prod -o snapshots/discovery.json"
```

## Security scan

```bash
make security-scan
```

## Using docker-compose

```bash
docker-compose up -d
docker-compose exec oci-toolkit /bin/bash
```