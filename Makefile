SHELL := /bin/bash

RUBY_VERSION ?= 4.0.0
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

ARCH := $(shell uname -m | sed 's/arm64/aarch64/' | sed 's/amd64/x86_64/')
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
TARGET ?= $(ARCH)-$(OS)

RUBY_DIR := build/ruby-$(RUBY_VERSION)-$(TARGET)
STUB := build/stub

.PHONY: all clean stub herb test help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

all: herb ## Build herb as a test case

$(STUB): data/ext/stub.c
	@echo "==> Compiling stub..."
	@mkdir -p build
	$(CC) -O2 -Wall -Wextra -o $@ $<

build/write-footer: data/ext/write-footer.c
	@mkdir -p build
	$(CC) -O2 -Wall -Wextra -o $@ $<

build/stub-linux: data/ext/stub.c
	@echo "==> Cross-compiling stub for Linux..."
	@mkdir -p build
	docker run --rm -v $(PWD):/src -w /src alpine:3.21 \
		sh -c "apk add --no-cache gcc musl-dev >/dev/null 2>&1 && \
		       cc -O2 -Wall -Wextra -static -o build/stub-linux data/ext/stub.c"

stub: $(STUB) build/write-footer ## Compile native tools

$(RUBY_DIR)/bin/ruby:
	@RUBOX_DATA_DIR=$(PWD)/data \
		data/scripts/build-ruby.sh \
		--ruby-version $(RUBY_VERSION) \
		--target $(TARGET) \
		--output $(RUBY_DIR) \
		--jobs $(JOBS)

ruby: $(RUBY_DIR)/bin/ruby ## Build static Ruby

herb: stub $(RUBY_DIR)/bin/ruby ## Package herb as a test case
	@$(RUBY_DIR)/bin/gem list -i herb >/dev/null 2>&1 || \
		$(RUBY_DIR)/bin/gem install herb --no-document
	@RUBOX_DATA_DIR=$(PWD)/data \
		data/scripts/package.sh \
		--ruby-dir $(RUBY_DIR) \
		--gem herb --entry herb \
		--stub $(STUB) --output build/herb

test: ## Run test suite
	@./test/test-packaging.sh

clean: ## Remove all build artifacts
	rm -rf build/
