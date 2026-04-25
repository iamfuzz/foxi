SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ARCHES    ?= x86_64 aarch64
IMAGE_TAG ?= latest
S3_BUCKET ?=
AWS_REGION ?= us-east-1
AMI_NAME  ?= foxi-$(shell date -u +%Y%m%d%H%M)

export ARCHES IMAGE_TAG S3_BUCKET AWS_REGION AMI_NAME

.PHONY: help packages image ami check-updates clean

help:
	@echo "Foxi Linux build targets:"
	@echo ""
	@echo "  make packages       Build APK packages with melange"
	@echo "  make image          Build OCI image with apko"
	@echo "  make ami            Create EC2 AMI (requires AWS creds + S3_BUCKET)"
	@echo "  make check-updates  Check for upstream kernel updates"
	@echo "  make clean          Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  ARCHES=$(ARCHES)"
	@echo "  S3_BUCKET=$(S3_BUCKET)"
	@echo "  AWS_REGION=$(AWS_REGION)"
	@echo "  AMI_NAME=$(AMI_NAME)"

packages:
	@chmod +x scripts/build-packages.sh
	scripts/build-packages.sh

image: packages
	@chmod +x scripts/build-image.sh
	scripts/build-image.sh

ami: image
	@[ -n "$(S3_BUCKET)" ] || (echo "ERROR: S3_BUCKET is not set"; exit 1)
	@chmod +x scripts/build-ami.sh
	sudo --preserve-env scripts/build-ami.sh

check-updates:
	@chmod +x scripts/check-updates.sh
	scripts/check-updates.sh kernel

clean:
	rm -rf dist/
	find packages -mindepth 2 -name '*.apk' -delete
	find packages -mindepth 2 -name 'APKINDEX.tar.gz' -delete
