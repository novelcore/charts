HACK_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CONTAINER ?= docker

hack-image:
	$(CONTAINER) build -t kubecore-rules-dashboards-hack:latest $(HACK_PATH)

# Synchronize rules and dashboards
hack: hack-image
	$(CONTAINER) run --rm \
		--volume "$(HACK_PATH)/../..:/kubecore" \
		-w /kubecore/hack/rules-and-dashboards \
		kubecore-rules-dashboards-hack:latest

# Run locally (requires Go and dependencies)
hack-local:
	cd $(HACK_PATH) && go run main.go

