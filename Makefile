# Copyright 2017 Ribose Inc.
# - Ronald Tse

.PHONY: refresh-ecr pull pull-build %-chain \
	docker-squash-exists stats \
	docker-gc docker-clean-volumes docker-clean docker-clean-all

SHELL := /bin/bash

NS_LOCAL := ribose
# TODO: update NS_REMOTE
NS_REMOTE := ribose

DOCKER_RUN=docker run
DOCKER_EXEC=docker exec

# Using cap-add and security-opt instead of --privileged flag
DOCKER_RUN_SYSTEMD_FLAGS=--security-opt seccomp=unconfined --cap-add SYS_ADMIN --cap-add NET_ADMIN
DOCKER_RUN_SYSTEMD=$(DOCKER_RUN) $(DOCKER_RUN_SYSTEMD_FLAGS)

DOCKER_SQUASH_IMG=ribose/docker-squash:latest
DOCKER_SQUASH_CMD=$(DOCKER_RUN) --rm -v $(shell which docker):/usr/bin/docker -v /var/run/docker.sock:/var/run/docker.sock -v /docker_tmp $(DOCKER_SQUASH_IMG)

# Versions
VERSION_CENTOS=7.4

# Root container images
ROOT_CONTAINER_CENTOS=centos:7.4.1708

VERSION := $(VERSION_CENTOS)
ROOT_CONTAINER := $(ROOT_CONTAINER_CENTOS)

CONTAINER_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)
ifeq ($(CONTAINER_BRANCH),HEAD)
CONTAINER_BRANCH := master
endif
CONTAINER_COMMIT ?= $(shell git rev-parse --short HEAD)
REPO_GIT_NAME ?= $(shell git config --get remote.origin.url)

pull:	pull-build-rhel

pull-build:
	docker pull $(ROOT_CONTAINER_CENTOS); \
	docker pull $(NS_REMOTE)/centos-systemd:$(VERSION_CENTOS).$(CONTAINER_BRANCH); \

docker-squash-exists:
	if [ -z "$$(docker history -q $(DOCKER_SQUASH_IMG))" ]; then \
		docker pull $(DOCKER_SQUASH_IMG); \
	fi

## Basic Containers

define ROOT_CONTAINER_TASKS

# All */Dockerfiles are intermediate files, removed after using
# Comment this out when debugging
.INTERMEDIATE: $(TARGET)/Dockerfile

.PHONY: build-$(TARGET) clean-local-$(TARGET) kill-$(TARGET) rm-$(TARGET) \
	rmf-$(TARGET) squash-$(TARGET) tag-$(TARGET) push-$(TARGET) sp-$(TARGET) \
	bsp-$(TARGET) tp-$(TARGET) btp-$(TARGET) bt-$(TARGET) bs-$(TARGET) \
	clean-remote-$(TARGET) run-$(TARGET)

$(eval CONTAINER_LOCAL_NAME := $(NS_LOCAL)/$(TARGET):$(VERSION).$(CONTAINER_BRANCH))
$(eval CONTAINER_REMOTE_NAME := $(NS_REMOTE)/$(TARGET):$(VERSION).$(CONTAINER_BRANCH))

# Only the first line is eval'ed by bash
$(TARGET)/Dockerfile:
	VERSION=$(VERSION); \
	ROOT_CONTAINER=$(ROOT_CONTAINER); \
	CONTAINER_BRANCH=$(CONTAINER_BRANCH); \
	NS_REMOTE=$(NS_REMOTE); \
	FROM_LINE=`head -1 $$@.nsd-centos-systemd-nsd-4.1.17-dev.in`; \
	FROM_LINE_EVALED=`eval "echo \"$$$${FROM_LINE}\""`; \
		echo "$$$${FROM_LINE_EVALED}" > $$@; \
		sed '1d' $$@.nsd-centos-systemd-nsd-4.1.17-dev.in >> $$@

build-$(TARGET):	$(TARGET)/Dockerfile
	cat $(TARGET)/Dockerfile
	docker build --rm \
		-t $(CONTAINER_LOCAL_NAME) \
		-f $(TARGET)/Dockerfile \
		--label dnsnamespace-base-container-root=$(ROOT_CONTAINER) \
		--label dnsnamespace-base-container-source=$(REPO_GIT_NAME)/$(TARGET) \
		--label dnsnamespace-base-container=$(CONTAINER_LOCAL_NAME) \
		--label dnsnamespace-base-container-remote=$(CONTAINER_REMOTE_NAME) \
		--label dnsnamespace-base-container-version=$(VERSION) \
		--label dnsnamespace-base-container-commit=$(CONTAINER_COMMIT) \
		--label dnsnamespace-base-container-commit-branch=$(CONTAINER_BRANCH) \
		.

clean-local-$(TARGET):
	docker rmi -f $(CONTAINER_LOCAL_NAME)

clean-remote-$(TARGET):
	docker rmi -f $(CONTAINER_REMOTE_NAME)

run-$(TARGET):
	CONTAINER_ID=`$(DOCKER_RUN_SYSTEMD) -dit --name=test-$(TARGET) $(CONTAINER_REMOTE_NAME)`; \
	if [ "$$$${CONTAINER_ID}" == "" ]; then \
	  echo "Container unable to start."; \
    exit 1; \
  fi; \
	docker exec -it $$$${CONTAINER_ID} /bin/bash

kill-$(TARGET):
	docker kill test-$(TARGET)

rm-$(TARGET):
	docker rm test-$(TARGET)

rmf-$(TARGET):
	-docker rm -f test-$(TARGET)

squash-$(TARGET):	docker-squash-exists $(TARGET)/Dockerfile
	FROM_IMAGE=`head -1 $(TARGET)/Dockerfile | cut -f 2 -d ' '`; \
	$(DOCKER_SQUASH_CMD) -t $(CONTAINER_REMOTE_NAME) \
		-f $$$${FROM_IMAGE} \
		$(CONTAINER_LOCAL_NAME) #\ TODO: enable this line again if NS_LOCAL and NS_REMOTE are different
		# && $(MAKE) clean-local-$(TARGET)

tag-$(TARGET):
	CONTAINER_ID=`docker images -q $(CONTAINER_LOCAL_NAME)`; \
	if [ "$$$${CONTAINER_ID}" == "" ]; then \
		echo "Container non-existant, check 'docker images'."; \
		exit 1; \
	fi; \
	docker tag $$$${CONTAINER_ID} $(CONTAINER_REMOTE_NAME) \
		&& $(MAKE) clean-local-$(TARGET)

push-$(TARGET):
	docker push $(CONTAINER_REMOTE_NAME)

sp-$(TARGET):
	$(MAKE) squash-$(TARGET) push-$(TARGET)

bsp-$(TARGET):
	$(MAKE) build-$(TARGET) sp-$(TARGET)

tp-$(TARGET):
	$(MAKE) tag-$(TARGET) push-$(TARGET)

btp-$(TARGET):
	$(MAKE) build-$(TARGET) tp-$(TARGET)

bt-$(TARGET):
	$(MAKE) build-$(TARGET) tag-$(TARGET)

bs-$(TARGET):
	$(MAKE) build-$(TARGET) squash-$(TARGET)

endef

# e.g., make build-centos
CONTAINERS_CENTOS := dns-centos-systemd nsd

$(foreach TARGET,$(CONTAINERS_CENTOS),$(eval $(ROOT_CONTAINER_TASKS)))

## Cleanup commands
docker-clean:
	docker rm -v `docker ps --filter status=exited -q 2>/dev/null` 2>/dev/null; \
	docker rmi `docker images --filter dangling=true -q 2>/dev/null` 2>/dev/null; \
	exit 0

docker-gc:
	-$(DOCKER_RUN) --rm -v /var/run/docker.sock:/var/run/docker.sock spotify/docker-gc

docker-clean-volumes:
	-$(DOCKER_RUN) --rm -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker:/var/lib/docker martin/docker-cleanup-volumes

docker-clean-all:	docker-clean docker-gc docker-clean-volumes

stats:
	docker stats `docker ps -q`

# vim: set noexpandtab:
