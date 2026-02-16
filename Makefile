.PHONY: build run clean test security-scan

IMAGE_NAME := oci-bash-toolkit
IMAGE_TAG := latest

build:
	docker build --no-cache -t $(IMAGE_NAME):$(IMAGE_TAG) .

run:
	docker run --rm -it \
		-v $(HOME)/.oci:/home/ociuser/.oci:ro \
		-v $(PWD)/snapshots:/toolkit/snapshots \
		-v $(PWD)/plans:/toolkit/plans \
		$(IMAGE_NAME):$(IMAGE_TAG)

# Run a specific script
run-script:
	@test -n "$(SCRIPT)" || (echo "Usage: make run-script SCRIPT=tenancy/discover.sh"; exit 1)
	docker run --rm -it \
		-v $(HOME)/.oci:/home/ociuser/.oci:ro \
		-v $(PWD)/snapshots:/toolkit/snapshots \
		-v $(PWD)/plans:/toolkit/plans \
		$(IMAGE_NAME):$(IMAGE_TAG) $(SCRIPT)

security-scan:
	docker scan $(IMAGE_NAME):$(IMAGE_TAG) || \
	trivy image $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) || true

test:
	docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) bash --version
	docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) jq --version
	docker run --rm $(IMAGE_NAME):$(IMAGE_NAME) oci --version