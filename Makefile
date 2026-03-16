SHELL := /bin/bash

RUBY_VERSION ?= 4.0.0
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Auto-detect target
ARCH := $(shell uname -m | sed 's/arm64/aarch64/' | sed 's/amd64/x86_64/')
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
TARGET ?= $(ARCH)-$(OS)

RUBY_DIR := build/ruby-$(RUBY_VERSION)-$(TARGET)
STUB := build/stub

.PHONY: all clean ruby stub herb herb-gemfile test test-cache help gems \
        stub-linux ruby-linux herb-linux test-linux

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

all: herb ## Build everything (herb test case)

# ---- Stub ----

$(STUB): src/stub.c
	@echo "==> Compiling stub..."
	@mkdir -p build
	$(CC) -O2 -Wall -Wextra -o $@ $<

build/write-footer: src/write-footer.c
	@mkdir -p build
	$(CC) -O2 -Wall -Wextra -o $@ $<

stub: $(STUB) build/write-footer ## Compile the self-extracting stub and tools

build/stub-linux: src/stub.c ## Cross-compile stub for Linux (via Docker)
	@echo "==> Cross-compiling stub for Linux..."
	@mkdir -p build
	docker run --rm -v $(PWD):/src -w /src alpine:3.21 \
		sh -c "apk add --no-cache gcc musl-dev >/dev/null 2>&1 && \
		       cc -O2 -Wall -Wextra -static -o build/stub-linux src/stub.c"

stub-linux: build/stub-linux ## Build stub for Linux

# ---- Ruby ----

$(RUBY_DIR)/bin/ruby:
	@./scripts/build-ruby.sh \
		--ruby-version $(RUBY_VERSION) \
		--target $(TARGET) \
		--output $(RUBY_DIR) \
		--jobs $(JOBS)

ruby: $(RUBY_DIR)/bin/ruby ## Build static Ruby for current platform

ruby-linux: ## Build static Ruby for Linux (via Docker)
	@./scripts/build-ruby.sh \
		--ruby-version $(RUBY_VERSION) \
		--target $(ARCH)-linux \
		--output build/ruby-$(RUBY_VERSION)-$(ARCH)-linux \
		--jobs $(JOBS)

# ---- Gems ----

gems: $(RUBY_DIR)/bin/ruby ## Install herb gem into built Ruby
	@$(RUBY_DIR)/bin/gem install herb --no-document 2>&1 | tail -1

# ---- Herb (gem mode) ----

herb: $(STUB) gems ## Package herb as single binary (gem mode)
	@./scripts/package.sh \
		--ruby-dir $(RUBY_DIR) \
		--gem herb \
		--entry herb \
		--stub $(STUB) \
		--output build/herb

# ---- Herb (gemfile mode) ----

herb-gemfile: $(STUB) $(RUBY_DIR)/bin/ruby ## Package herb via Gemfile (gemfile mode)
	@./scripts/package.sh \
		--ruby-dir $(RUBY_DIR) \
		--gemfile packaging/herb/Gemfile \
		--entry herb \
		--stub $(STUB) \
		--output build/herb-gemfile

# ---- Herb Linux ----

herb-linux: stub-linux ruby-linux ## Package herb for Linux
	@LINUX_RUBY=build/ruby-$(RUBY_VERSION)-$(ARCH)-linux && \
	$$LINUX_RUBY/bin/gem install herb --no-document 2>&1 | tail -1 && \
	./scripts/package.sh \
		--ruby-dir $$LINUX_RUBY \
		--gem herb \
		--entry herb \
		--stub build/stub-linux \
		--no-fix-dylibs \
		--output build/herb-linux

# ---- Tests ----

test: herb ## Test the packaged herb binary
	@echo "==> Testing packaged herb binary..."
	@echo ""
	@echo "--- version ---"
	@build/herb --version
	@echo ""
	@echo "--- parse ---"
	@echo '<div><%= "hello" %></div>' | build/herb parse -
	@echo ""
	@echo "--- lex ---"
	@echo '<a href="#">link</a>' | build/herb lex - | head -5
	@echo "..."
	@echo ""
	@echo "==> All tests passed."

test-cache: herb ## Test caching behavior
	@echo "==> Testing cache..."
	@rm -rf ~/.cache/portable-cruby/
	@echo "--- First run (cold cache) ---"
	@time build/herb --version
	@echo ""
	@echo "--- Second run (warm cache) ---"
	@time build/herb --version
	@echo ""
	@echo "--- Cache contents ---"
	@ls ~/.cache/portable-cruby/ 2>/dev/null || echo "(no cache dir)"
	@echo ""
	@echo "--- No-cache mode ---"
	@PORTABLE_CRUBY_NO_CACHE=1 build/herb --version
	@echo ""
	@echo "==> Cache tests passed."

test-linux: herb-linux ## Test Linux binary in Docker
	@echo "==> Testing Linux binary in Docker..."
	docker run --rm -v $(PWD)/build:/app alpine:3.21 \
		sh -c "apk add --no-cache zstd >/dev/null 2>&1 && /app/herb-linux --version"

# ---- Clean ----

clean: ## Remove all build artifacts
	rm -rf build/

clean-cache: ## Remove extraction cache
	rm -rf ~/.cache/portable-cruby/
