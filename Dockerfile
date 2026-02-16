# syntax=docker/dockerfile:1.4

# ============================================================================
# Build stage: Install dependencies in minimal footprint
# ============================================================================
FROM alpine:3.19 AS builder

# Install build dependencies
RUN apk add --no-cache \
	bash=5.3.9-r0 \
	jq=1.8.1-r0 \
	python3=3.14.2-r0 \
	py3-pip=25.3-r0 \
	ca-certificates=20240226-r0 \
	&& python3 -m venv /opt/venv \
	&& /opt/venv/bin/pip install --no-cache-dir oci-cli==3.39.0

# ============================================================================
# Final stage: Minimal runtime image
# ============================================================================
FROM alpine:3.19

LABEL maintainer="Miklos Karpati" \
	description="OCI Bash Toolkit - Shell automation for Oracle Cloud Infrastructure" \
	version="1.0.0"

# Install runtime dependencies only
RUN apk add --no-cache \
	bash=5.2.21-r0 \
	jq=1.7.1-r0 \
	python3=3.11.8-r0 \
	ca-certificates=20240226-r0 \
	&& apk upgrade --no-cache \
	&& rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copy OCI CLI from builder
COPY --from=builder /opt/venv /opt/venv

# Create non-root user with minimal permissions
RUN addgroup -g 1000 -S ociuser \
	&& adduser -u 1000 -S ociuser -G ociuser -h /home/ociuser -s /bin/bash \
	&& mkdir -p /home/ociuser/.oci /toolkit/snapshots /toolkit/plans \
	&& chown -R ociuser:ociuser /home/ociuser /toolkit

# Copy toolkit files
COPY --chown=ociuser:ociuser compute/ /toolkit/compute/
COPY --chown=ociuser:ociuser lib/ /toolkit/lib/
COPY --chown=ociuser:ociuser network/ /toolkit/network/
COPY --chown=ociuser:ociuser tenancy/ /toolkit/tenancy/
COPY --chown=ociuser:ociuser docs/ /toolkit/docs/
COPY --chown=ociuser:ociuser README.md LICENSE /toolkit/

# Make scripts executable
RUN find /toolkit -type f -name "*.sh" -exec chmod +x {} \;

# Copy entrypoint
COPY --chown=ociuser:ociuser docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Set PATH to include OCI CLI and toolkit scripts
ENV PATH="/opt/venv/bin:/toolkit/compute:/toolkit/network:/toolkit/tenancy:${PATH}" \
	PYTHONUNBUFFERED=1 \
	OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

# Switch to non-root user
USER ociuser
WORKDIR /toolkit

# Validate installations
RUN bash --version | grep -q "version 5" \
	&& jq --version | grep -q "jq-1" \
	&& oci --version

# Health check (validates OCI CLI and jq are functional)
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
	CMD jq --version && oci --version || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]
