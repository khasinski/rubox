SHELL := /bin/bash

RUBY_VERSION ?= 4.0.0
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Auto-detect target
ARCH := $(shell uname -m | sed 's/arm64/aarch64/' | sed 's/amd64/x86_64/')
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
TARGET ?= $(ARCH)-$(OS)

RUBY_DIR := build/ruby-$(RUBY_VERSION)-$(TARGET)
STUB := build/stub

.PHONY: all clean ruby stub herb test help gems

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

all: herb ## Build everything (herb test case)

# --- Stub ---

$(STUB): src/stub.c
	@echo "==> Compiling stub..."
	@mkdir -p build
	$(CC) -O2 -Wall -Wextra -o $@ $<

stub: $(STUB) ## Build the stub binary

# --- Ruby ---

$(RUBY_DIR)/bin/ruby:
	@./scripts/build-ruby.sh \
		--ruby-version $(RUBY_VERSION) \
		--target $(TARGET) \
		--output $(RUBY_DIR) \
		--jobs $(JOBS)

ruby: $(RUBY_DIR)/bin/ruby ## Build Ruby interpreter

# --- Gems ---

gems: $(RUBY_DIR)/bin/ruby ## Install herb gem into built Ruby
	@echo "==> Installing herb gem..."
	$(RUBY_DIR)/bin/gem install herb --no-document

# --- Herb (test case) ---

herb: $(STUB) gems ## Package herb as single binary
	@./scripts/package.sh \
		--ruby-dir $(RUBY_DIR) \
		--gem herb \
		--entry herb \
		--stub $(STUB) \
		--output build/herb

# --- Test ---

test: herb ## Test the packaged herb binary
	@echo "==> Testing packaged herb binary..."
	@echo ""
	@echo "--- herb --version ---"
	@build/herb --version || true
	@echo ""
	@echo "--- herb --help ---"
	@build/herb --help 2>&1 | head -20 || true
	@echo ""
	@echo '--- herb parse (inline) ---'
	@echo '<div><%= "hello" %></div>' | build/herb parse - || true
	@echo ""
	@echo "==> Tests complete."

# --- Clean ---

clean: ## Remove all build artifacts
	rm -rf build/
