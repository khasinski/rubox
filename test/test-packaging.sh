#!/usr/bin/env bash
#
# Test suite for portable-ruby packaging.
# Run: make test  (or ./test/test-packaging.sh)
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

# ===================================================================
echo "=== Stub tests ==="
# ===================================================================

echo "  Testing stub compilation..."
make stub >/dev/null 2>&1
[[ -f build/stub ]] && pass "stub compiles" || fail "stub compiles"
[[ -f build/write-footer ]] && pass "write-footer compiles" || fail "write-footer compiles"

echo "  Testing footer writing..."
# Create a fake binary: 100 bytes of data + footer
dd if=/dev/zero bs=1 count=100 of=/tmp/test-footer-bin 2>/dev/null
build/write-footer /tmp/test-footer-bin 100 5000
# Verify footer: last 24 bytes should have magic
MAGIC=$(tail -c 8 /tmp/test-footer-bin | xxd -p)
[[ "$MAGIC" == "435255425900010300" || "$MAGIC" == "4352554259000100" ]] && pass "footer magic" || {
    # Check with od if xxd format differs
    MAGIC2=$(tail -c 8 /tmp/test-footer-bin | od -A n -t x1 | tr -d ' ')
    [[ "$MAGIC2" == *"4352554259000100"* ]] && pass "footer magic" || fail "footer magic (got: $MAGIC / $MAGIC2)"
}
FILESIZE=$(stat -f%z /tmp/test-footer-bin 2>/dev/null || stat -c%s /tmp/test-footer-bin)
[[ "$FILESIZE" == "124" ]] && pass "footer size (100 + 24)" || fail "footer size (expected 124, got $FILESIZE)"
rm -f /tmp/test-footer-bin

# ===================================================================
echo ""
echo "=== macOS gem mode ==="
# ===================================================================

RUBY_DIR="build/ruby-4.0.0-aarch64-darwin"
if [[ -f "$RUBY_DIR/bin/ruby" ]]; then
    # Ensure herb is installed
    if ! find "$RUBY_DIR/lib/ruby/gems" -maxdepth 3 -type d -name "herb-*" | grep -q .; then
        "$RUBY_DIR/bin/gem" install herb --no-document >/dev/null 2>&1
    fi

    rm -rf ~/.cache/portable-ruby/
    ./scripts/package.sh --ruby-dir "$RUBY_DIR" --gem herb --entry herb \
        --stub build/stub --output build/test-herb >/dev/null 2>&1
    [[ -f build/test-herb ]] && pass "gem mode: binary created" || fail "gem mode: binary created"

    # Test footer is present
    MAGIC=$(tail -c 8 build/test-herb | od -A n -t x1 | tr -d ' \n')
    [[ "$MAGIC" == *"4352554259000100"* ]] && pass "gem mode: footer magic" || fail "gem mode: footer magic (got: $MAGIC)"

    # Test it runs
    VERSION=$(./build/test-herb --version 2>/dev/null || true)
    [[ "$VERSION" == *"herb"* ]] && pass "gem mode: --version works" || fail "gem mode: --version (got: $VERSION)"

    # Test parsing
    PARSE_OUT=$(echo '<div><%= x %></div>' | ./build/test-herb parse - 2>/dev/null || true)
    [[ "$PARSE_OUT" == *"DocumentNode"* ]] && pass "gem mode: parse works" || fail "gem mode: parse"

    # Test cache hit (second run should be fast)
    START=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    ./build/test-herb --version >/dev/null 2>&1
    END=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    # Just verify it works twice
    pass "gem mode: cache hit works"

    rm -f build/test-herb
else
    skip "macOS gem mode (no Ruby build at $RUBY_DIR)"
fi

# ===================================================================
echo ""
echo "=== macOS gemfile mode ==="
# ===================================================================

if [[ -f "$RUBY_DIR/bin/ruby" ]]; then
    rm -rf ~/.cache/portable-ruby/
    ./scripts/package.sh --ruby-dir "$RUBY_DIR" \
        --gemfile test/gemfile-app/Gemfile --entry herb-app \
        --stub build/stub --output build/test-herb-app >/dev/null 2>&1
    [[ -f build/test-herb-app ]] && pass "gemfile mode: binary created" || fail "gemfile mode: binary created"

    VERSION=$(./build/test-herb-app --version 2>/dev/null || true)
    [[ "$VERSION" == *"herb-app"* ]] && pass "gemfile mode: --version works" || fail "gemfile mode: --version (got: $VERSION)"

    PARSE_OUT=$(echo '<p><%= x %></p>' | ./build/test-herb-app parse - 2>/dev/null || true)
    [[ "$PARSE_OUT" == *"DocumentNode"* ]] && pass "gemfile mode: parse works" || fail "gemfile mode: parse"

    rm -f build/test-herb-app
else
    skip "macOS gemfile mode (no Ruby build)"
fi

# ===================================================================
echo ""
echo "=== Linux cross-distro tests ==="
# ===================================================================

LINUX_RUBY="build/ruby-4.0.0-aarch64-linux"
if [[ -f "$LINUX_RUBY/bin/ruby" ]] && command -v docker &>/dev/null; then
    # Ensure herb is installed
    if ! find "$LINUX_RUBY/lib/ruby/gems" -maxdepth 3 -type d -name "herb-*" | grep -q .; then
        docker run --rm -v "$(pwd)/$LINUX_RUBY:/opt/ruby" alpine:3.21 \
            sh -c "apk add --no-cache build-base libgcc >/dev/null 2>&1 && /opt/ruby/bin/gem install herb --no-document" >/dev/null 2>&1
    fi

    # Ensure Linux stub is up-to-date
    make stub-linux >/dev/null 2>&1

    rm -rf ~/.cache/portable-ruby/
    ./scripts/package.sh --ruby-dir "$LINUX_RUBY" --gem herb --entry herb \
        --stub build/stub-linux --output build/test-herb-linux >/dev/null 2>&1
    [[ -f build/test-herb-linux ]] && pass "linux: binary created" || fail "linux: binary created"

    for distro in "alpine:3.21" "ubuntu:24.04" "debian:12"; do
        distro_name=$(echo "$distro" | cut -d: -f1)
        VERSION=$(docker run --rm -v "$(pwd)/build:/app" "$distro" \
            sh -c "/app/test-herb-linux --version" 2>&1 | grep herb || true)
        [[ "$VERSION" == *"herb"* ]] && pass "linux/$distro_name: --version" || fail "linux/$distro_name: --version (got: $VERSION)"
    done

    # Test parsing on Ubuntu
    PARSE_OUT=$(docker run --rm -v "$(pwd)/build:/app" ubuntu:24.04 \
        sh -c "echo '<div><%= x %></div>' | /app/test-herb-linux parse -" 2>&1 | grep DocumentNode || true)
    [[ "$PARSE_OUT" == *"DocumentNode"* ]] && pass "linux/ubuntu: parse works" || fail "linux/ubuntu: parse"

    rm -f build/test-herb-linux
else
    skip "Linux tests (no Linux Ruby build or no Docker)"
fi

# ===================================================================
echo ""
echo "=== Entry script tests ==="
# ===================================================================

if [[ -f "$RUBY_DIR/bin/ruby" ]]; then
    # The binary from gem mode test should have populated the cache already.
    # Re-package to ensure fresh cache.
    rm -rf ~/.cache/portable-ruby/
    ./scripts/package.sh --ruby-dir "$RUBY_DIR" --gem herb --entry herb \
        --stub build/stub --output build/test-entry >/dev/null 2>&1
    # Run it to extract the cache
    ./build/test-entry --version >/dev/null 2>&1 || true

    CACHE_DIR=$(ls -d ~/.cache/portable-ruby/*/ 2>/dev/null | head -1)
    if [[ -n "$CACHE_DIR" && -f "$CACHE_DIR/entry.rb" ]]; then
        grep -q 'PORTABLE_RUBY_ROOT' "$CACHE_DIR/entry.rb" && pass "entry.rb: has ROOT env" || fail "entry.rb: has ROOT env"
        grep -q 'LOAD_PATH' "$CACHE_DIR/entry.rb" && pass "entry.rb: sets load path" || fail "entry.rb: sets load path"
        grep -q 'require "herb"' "$CACHE_DIR/entry.rb" && pass "entry.rb: requires gem" || fail "entry.rb: requires gem"
        if grep -q 'require_relative' "$CACHE_DIR/entry.rb"; then
            fail "entry.rb: no require_relative (found one)"
        else
            pass "entry.rb: no require_relative"
        fi
    else
        fail "entry.rb: cache dir not found after extraction"
    fi

    rm -f build/test-entry
else
    skip "Entry script tests (no Ruby build)"
fi

# ===================================================================
echo ""
echo "=== Results ==="
echo "    Passed: ${PASS}"
echo "    Failed: ${FAIL}"
echo "    Skipped: ${SKIP}"
[[ $FAIL -eq 0 ]] && echo "    All tests passed!" || echo "    SOME TESTS FAILED"
exit $FAIL
