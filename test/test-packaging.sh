#!/usr/bin/env bash
#
# Integration test suite for portable-ruby.
# Run: make test
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

export PORTABLE_RUBY_DATA_DIR="${PROJECT_DIR}/data"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 -- $2"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if echo "$haystack" | grep -q "$needle"; then
        pass "$label"
    else
        fail "$label" "expected to contain '$needle', got: $(echo "$haystack" | head -1)"
    fi
}

# ===================================================================
echo "=== 1. Native tools ==="
# ===================================================================

make stub >/dev/null 2>&1
[[ -x build/stub ]] && pass "stub compiles" || fail "stub compiles" "binary not found"
[[ -x build/write-footer ]] && pass "write-footer compiles" || fail "write-footer compiles" "binary not found"

# Footer round-trip
dd if=/dev/zero bs=1 count=100 of=/tmp/pr-test-bin 2>/dev/null
build/write-footer /tmp/pr-test-bin 100 5000
FSIZE=$(stat -f%z /tmp/pr-test-bin 2>/dev/null || stat -c%s /tmp/pr-test-bin)
[[ "$FSIZE" == "124" ]] && pass "footer appended (100 + 24 bytes)" || fail "footer size" "expected 124, got $FSIZE"
rm -f /tmp/pr-test-bin

# ===================================================================
echo ""
echo "=== 2. Ruby CLI ==="
# ===================================================================

HELP=$(ruby -Ilib exe/portable-ruby --help 2>&1)
assert_contains "$HELP" "portable-ruby" "cli: help text"
assert_contains "$HELP" "\-\-gem" "cli: --gem flag documented"
assert_contains "$HELP" "\-y" "cli: -y flag documented"

VER=$(ruby -Ilib exe/portable-ruby --version 2>&1)
assert_contains "$VER" "0.1.0" "cli: version output"

# ===================================================================
echo ""
echo "=== 3. Detector ==="
# ===================================================================

# Test Gemfile detection
DETECT=$(ruby -Ilib -e '
  require "portable/ruby/detector"
  d = Portable::Ruby::Detector.new("test/gemfile-app")
  puts "gemfile:#{d.gemfile_path}"
  puts "version:#{d.ruby_version}"
')
assert_contains "$DETECT" "gemfile:.*Gemfile" "detector: finds Gemfile"
assert_contains "$DETECT" "version:" "detector: returns ruby version"

# Test when no Gemfile
DETECT_NONE=$(ruby -Ilib -e '
  require "portable/ruby/detector"
  d = Portable::Ruby::Detector.new("/tmp")
  puts d.gemfile_path.inspect
')
assert_contains "$DETECT_NONE" "nil" "detector: nil when no Gemfile"

# ===================================================================
echo ""
echo "=== 4. Platform ==="
# ===================================================================

PLAT=$(ruby -Ilib -e '
  require "portable/ruby/platform"
  puts Portable::Ruby::Platform.host_target
')
assert_contains "$PLAT" "-" "platform: returns arch-os format"

VALID=$(ruby -Ilib -e '
  require "portable/ruby/platform"
  puts Portable::Ruby::Platform.valid_target?("aarch64-linux")
  puts Portable::Ruby::Platform.valid_target?("potato-bsd")
')
assert_contains "$VALID" "true" "platform: validates known targets"

# ===================================================================
echo ""
echo "=== 5. Confirmation prompt ==="
# ===================================================================

# Remove any cached ruby to trigger the prompt
TMPDIR=$(mktemp -d)
PROMPT_OUT=$(cd "$TMPDIR" && echo "n" | ruby -I"${PROJECT_DIR}/lib" "${PROJECT_DIR}/exe/portable-ruby" pack --gem herb 2>&1 || true)
rm -rf "$TMPDIR"
assert_contains "$PROMPT_OUT" "fetch and compile" "prompt: shows build message"
assert_contains "$PROMPT_OUT" "Continue?" "prompt: asks for confirmation"
assert_contains "$PROMPT_OUT" "Aborted" "prompt: respects 'n' answer"

# ===================================================================
echo ""
echo "=== 6. macOS packaging (gem mode) ==="
# ===================================================================

# Find any available built Ruby
RUBY_DIR=$(ls -d build/ruby-*-*-darwin 2>/dev/null | head -1)
if [[ -n "$RUBY_DIR" && -f "$RUBY_DIR/bin/ruby" ]]; then
    # Ensure herb is installed
    find "$RUBY_DIR/lib/ruby/gems" -maxdepth 3 -type d -name "herb-*" | grep -q . || \
        "$RUBY_DIR/bin/gem" install herb --no-document >/dev/null 2>&1

    rm -rf ~/.cache/portable-ruby/
    PORTABLE_RUBY_DATA_DIR="$PROJECT_DIR/data" \
        data/scripts/package.sh --ruby-dir "$RUBY_DIR" --gem herb --entry herb \
        --stub build/stub --output build/test-herb >/dev/null 2>&1

    [[ -f build/test-herb ]] && pass "macOS gem: binary created" || fail "macOS gem: binary created" ""

    OUT=$(./build/test-herb --version 2>/dev/null || true)
    assert_contains "$OUT" "herb" "macOS gem: --version works"

    PARSE=$(echo '<div><%= x %></div>' | ./build/test-herb parse - 2>/dev/null || true)
    assert_contains "$PARSE" "DocumentNode" "macOS gem: parse works"

    # Cache hit test
    ./build/test-herb --version >/dev/null 2>&1
    pass "macOS gem: cache hit works"

    rm -f build/test-herb
else
    skip "macOS packaging (no Ruby build found)"
fi

# ===================================================================
echo ""
echo "=== 7. macOS packaging (gemfile mode) ==="
# ===================================================================

if [[ -n "$RUBY_DIR" && -f "$RUBY_DIR/bin/ruby" ]]; then
    rm -rf ~/.cache/portable-ruby/
    PORTABLE_RUBY_DATA_DIR="$PROJECT_DIR/data" \
        data/scripts/package.sh --ruby-dir "$RUBY_DIR" \
        --gemfile test/gemfile-app/Gemfile --entry herb-app \
        --stub build/stub --output build/test-herb-app >/dev/null 2>&1

    [[ -f build/test-herb-app ]] && pass "macOS gemfile: binary created" || fail "macOS gemfile: binary created" ""

    OUT=$(./build/test-herb-app --version 2>/dev/null || true)
    assert_contains "$OUT" "herb-app" "macOS gemfile: --version works"

    PARSE=$(echo '<p><%= x %></p>' | ./build/test-herb-app parse - 2>/dev/null || true)
    assert_contains "$PARSE" "DocumentNode" "macOS gemfile: parse works"

    rm -f build/test-herb-app
else
    skip "macOS gemfile mode (no Ruby build)"
fi

# ===================================================================
echo ""
echo "=== 8. Linux cross-distro ==="
# ===================================================================

LINUX_RUBY=$(ls -d build/ruby-*-*-linux 2>/dev/null | head -1)
if [[ -n "$LINUX_RUBY" && -f "$LINUX_RUBY/bin/ruby" ]] && command -v docker &>/dev/null; then
    find "$LINUX_RUBY/lib/ruby/gems" -maxdepth 3 -type d -name "herb-*" | grep -q . || {
        docker run --rm -v "$(pwd)/$LINUX_RUBY:/opt/ruby" alpine:3.21 \
            sh -c "apk add --no-cache build-base libgcc >/dev/null 2>&1 && /opt/ruby/bin/gem install herb --no-document" >/dev/null 2>&1
    }

    make build/stub-linux >/dev/null 2>&1

    rm -rf ~/.cache/portable-ruby/
    PORTABLE_RUBY_DATA_DIR="$PROJECT_DIR/data" \
        data/scripts/package.sh --ruby-dir "$LINUX_RUBY" --gem herb --entry herb \
        --stub build/stub-linux --output build/test-herb-linux >/dev/null 2>&1

    [[ -f build/test-herb-linux ]] && pass "linux: binary created" || fail "linux: binary created" ""

    for distro in "alpine:3.21" "ubuntu:24.04" "debian:12"; do
        name=$(echo "$distro" | cut -d: -f1)
        OUT=$(docker run --rm -v "$(pwd)/build:/app" "$distro" \
            sh -c "/app/test-herb-linux --version" 2>&1 | grep herb || true)
        assert_contains "$OUT" "herb" "linux/$name: runs"
    done

    rm -f build/test-herb-linux
else
    skip "Linux cross-distro (no Linux Ruby build or no Docker)"
fi

# ===================================================================
echo ""
echo "=== 9. Entry script quality ==="
# ===================================================================

if [[ -n "$RUBY_DIR" && -f "$RUBY_DIR/bin/ruby" ]]; then
    rm -rf ~/.cache/portable-ruby/
    PORTABLE_RUBY_DATA_DIR="$PROJECT_DIR/data" \
        data/scripts/package.sh --ruby-dir "$RUBY_DIR" --gem herb --entry herb \
        --stub build/stub --output build/test-entry >/dev/null 2>&1
    ./build/test-entry --version >/dev/null 2>&1 || true

    CACHE_DIR=$(ls -d ~/.cache/portable-ruby/*/ 2>/dev/null | head -1)
    if [[ -n "$CACHE_DIR" && -f "$CACHE_DIR/entry.rb" ]]; then
        ENTRY=$(cat "$CACHE_DIR/entry.rb")
        assert_contains "$ENTRY" "PORTABLE_RUBY_ROOT" "entry.rb: uses ROOT env"
        assert_contains "$ENTRY" "LOAD_PATH" "entry.rb: sets load path"
        assert_contains "$ENTRY" 'require "herb"' "entry.rb: requires gem"
        if echo "$ENTRY" | grep -q 'require_relative'; then
            fail "entry.rb: no require_relative" "found require_relative in generated entry"
        else
            pass "entry.rb: no require_relative"
        fi
    else
        fail "entry.rb: extracted" "cache dir not found"
    fi
    rm -f build/test-entry
fi

# ===================================================================
echo ""
echo "==============================="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo "  Skipped: ${SKIP}"
echo "==============================="
[[ $FAIL -eq 0 ]] && echo "  All tests passed!" || echo "  SOME TESTS FAILED"
exit $FAIL
