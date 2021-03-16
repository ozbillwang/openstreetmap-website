RELEASE_TYPE ?= patch

CURRENT_VERSION := $(shell git ls-remote --tags | awk '{ print $$2}'| sort -nr | head -n1|sed 's/refs\/tags\///g')

ifndef CURRENT_VERSION
  CURRENT_VERSION := 0.0.0
endif

NEXT_VERSION := $(shell docker run --rm alpine/semver semver -c -i $(RELEASE_TYPE) $(CURRENT_VERSION))

help: ## help target
	@echo "$$HELP_TEXT"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / \
                {printf "\033[36m%-30s\033[0m  %s\n", $$1, $$2}' $(MAKEFILE_LIST)

current-version: ## make current-version
	@echo $(CURRENT_VERSION)

next-version: ## make next-version
	@echo $(NEXT_VERSION)

release: ## make release
	git checkout master;
	git tag $(NEXT_VERSION)
	git push --tags
