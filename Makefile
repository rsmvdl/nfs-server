IMAGE ?= ghcr.io/rsmvdl/nfs-server
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64

.PHONY: build push buildx-push shellcheck

build:
	docker build -t $(IMAGE):$(TAG) .

push: build
	docker push $(IMAGE):$(TAG)

buildx-push:
	docker buildx build --platform $(PLATFORMS) -t $(IMAGE):$(TAG) --push .

shellcheck:
	bash -n nfsd.sh
	sh -n healthcheck.sh



