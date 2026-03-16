#!/usr/bin/env bash
#
# Package a Ruby gem's CLI into a single self-extracting binary.
#
# Usage:
#   ./scripts/package.sh \
#     --ruby-dir build/ruby-4.0.0-aarch64-darwin \
#     --gem herb \
#     --entry herb \
#     --output build/herb
#
# The gems should already be installed into the ruby-dir via `gem install`.
# This script copies the Ruby installation + gems, creates an entry script,
# compresses everything, and appends it to the stub binary.
#
set -euo pipefail

RUBY_DIR=""
GEM_NAME=""
ENTRY_BIN=""
OUTPUT=""
STUB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ruby-dir) RUBY_DIR="$2"; shift 2 ;;
        --gem)      GEM_NAME="$2"; shift 2 ;;
        --entry)    ENTRY_BIN="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        --stub)     STUB="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$RUBY_DIR" || -z "$GEM_NAME" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 --ruby-dir DIR --gem NAME --output FILE [--entry BIN] [--stub FILE]"
    exit 1
fi

# Default entry bin to gem name
ENTRY_BIN="${ENTRY_BIN:-$GEM_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUBY_DIR="$(cd "$RUBY_DIR" && pwd)"

if [[ -z "$STUB" ]]; then
    STUB="${PROJECT_DIR}/build/stub"
fi

RUBY="${RUBY_DIR}/bin/ruby"
GEM_DIR="${RUBY_DIR}/lib/ruby/gems"

# Verify the gem is installed
if ! "${RUBY}" -e "require '${GEM_NAME}'" 2>/dev/null; then
    echo "ERROR: gem '${GEM_NAME}' is not installed in ${RUBY_DIR}"
    echo "Install it first: ${RUBY_DIR}/bin/gem install ${GEM_NAME}"
    exit 1
fi

# Find the gem's bin entry point
ENTRY_SCRIPT=""
# Check gem bin wrapper
if [[ -f "${RUBY_DIR}/bin/${ENTRY_BIN}" ]]; then
    ENTRY_SCRIPT="${RUBY_DIR}/bin/${ENTRY_BIN}"
fi

if [[ -z "$ENTRY_SCRIPT" ]]; then
    echo "ERROR: Entry binary '${ENTRY_BIN}' not found in ${RUBY_DIR}/bin/"
    exit 1
fi

echo "==> Packaging ${GEM_NAME} (entry: ${ENTRY_BIN})"
echo "    Ruby: ${RUBY_DIR}"

STAGING_DIR=$(mktemp -d)
PAYLOAD_FILE=$(mktemp)
trap 'rm -rf "$STAGING_DIR" "$PAYLOAD_FILE"' EXIT

echo "==> Staging payload..."

# 1. Copy Ruby binary
echo "    Copying Ruby interpreter..."
mkdir -p "${STAGING_DIR}/bin"
cp "${RUBY_DIR}/bin/ruby" "${STAGING_DIR}/bin/ruby"
chmod +x "${STAGING_DIR}/bin/ruby"

# 2. Copy Ruby stdlib (only what's needed)
echo "    Copying Ruby stdlib..."
mkdir -p "${STAGING_DIR}/lib"
cp -a "${RUBY_DIR}/lib/ruby" "${STAGING_DIR}/lib/ruby"

# 3. Remove unnecessary files to reduce size
echo "    Pruning unnecessary files..."

# Remove gem cache (copies of .gem files)
rm -rf "${STAGING_DIR}/lib/ruby/gems"/*/cache

# Remove build artifacts and source files from gems
find "${STAGING_DIR}/lib/ruby/gems" -name "*.c" -o -name "*.h" -o -name "*.o" | xargs rm -f 2>/dev/null || true
find "${STAGING_DIR}/lib/ruby/gems" -name "Makefile" -type f | xargs rm -f 2>/dev/null || true

# Remove doc directories
find "${STAGING_DIR}/lib/ruby/gems" -name "doc" -type d | xargs rm -rf 2>/dev/null || true

# Remove test/spec directories from gems
find "${STAGING_DIR}/lib/ruby/gems" \( -name "test" -o -name "spec" -o -name "tests" -o -name "specs" \) -type d | xargs rm -rf 2>/dev/null || true

# Remove sig/ directories (RBS type signatures)
find "${STAGING_DIR}/lib/ruby/gems" -name "sig" -type d | xargs rm -rf 2>/dev/null || true

# Remove bundled gem cache
rm -rf "${STAGING_DIR}/lib/ruby/gems"/*/cache

# Remove rdoc/ri data
find "${STAGING_DIR}" -name ".rdoc" -type d -o -name "ri" -type d | xargs rm -rf 2>/dev/null || true

# Remove fiddle extension (links to Homebrew libffi, not portable)
find "${STAGING_DIR}" -path "*/fiddle*" -type f -delete 2>/dev/null || true
find "${STAGING_DIR}" -path "*/fiddle*" -type d | xargs rm -rf 2>/dev/null || true

# Remove herb .bundle files for Ruby versions we don't need
# Keep only the one matching our Ruby major.minor
RUBY_MAJOR_MINOR=$("${RUBY}" -e 'puts RUBY_VERSION.split(".")[0..1].join(".")')
echo "    Keeping only herb.bundle for Ruby ${RUBY_MAJOR_MINOR}"
for ver_dir in "${STAGING_DIR}"/lib/ruby/gems/*/gems/herb-*/lib/herb/[0-9]*/; do
    ver=$(basename "$ver_dir")
    if [[ "$ver" != "$RUBY_MAJOR_MINOR" ]]; then
        rm -rf "$ver_dir"
    fi
done

echo "    Verifying native extensions are portable..."
PORTABILITY_OK=true
find "${STAGING_DIR}" -name "*.bundle" -o -name "*.so" 2>/dev/null | grep -v 'DWARF' | while read -r f; do
    short_path="${f#${STAGING_DIR}/}"
    if command -v otool &>/dev/null; then
        non_system=$(otool -L "$f" | tail -n +2 | grep -v '/usr/lib/' | grep -v '/System/' || true)
        if [[ -n "$non_system" ]]; then
            echo "    FAIL: ${short_path} has non-portable deps:"
            echo "$non_system" | sed 's/^/          /'
            PORTABILITY_OK=false
        else
            echo "    OK:   ${short_path}"
        fi
    fi
done
if [[ "$PORTABILITY_OK" == "false" ]]; then
    echo ""
    echo "ERROR: Non-portable dynamic dependencies detected!"
    echo "       Remove the offending extensions or statically link them."
    exit 1
fi

# 4. Create entry script
echo "    Creating entry script..."
# Find the gem version dir (e.g. "4.0.0")
GEM_VERSION_DIR=$(ls -1 "${STAGING_DIR}/lib/ruby/gems/" | head -1)

cat > "${STAGING_DIR}/entry.rb" << 'EOF'
# portable-cruby entry script
# Bootstraps the gem environment and runs the packaged CLI

root = ENV["PORTABLE_CRUBY_ROOT"]

# Cleanup handler - remove temp dir on exit if not cached
if cleanup_dir = ENV["PORTABLE_CRUBY_CLEANUP"]
  at_exit do
    require "fileutils"
    FileUtils.rm_rf(cleanup_dir) rescue nil
  end
end

# Set up gem paths pointing to our extracted location
EOF

# Write the gem path setup with the actual version dir
cat >> "${STAGING_DIR}/entry.rb" << PATHS
gem_dir = File.join(root, "lib", "ruby", "gems", "${GEM_VERSION_DIR}")
ENV["GEM_HOME"] = gem_dir
ENV["GEM_PATH"] = gem_dir
Gem.clear_paths

# Now load and run the gem's CLI
require 'rubygems'
gem '${GEM_NAME}'
load Gem.bin_path('${GEM_NAME}', '${ENTRY_BIN}')
PATHS

echo "    Entry script created."

# 5. Create compressed payload
echo "==> Creating compressed payload..."
cd "${STAGING_DIR}"

if command -v zstd &>/dev/null; then
    echo "    Using zstd compression..."
    tar cf - . | zstd -19 -T0 > "${PAYLOAD_FILE}"
else
    echo "    Using gzip compression (install zstd for better compression)..."
    tar czf "${PAYLOAD_FILE}" .
fi
cd "${PROJECT_DIR}"

PAYLOAD_SIZE=$(stat -f%z "${PAYLOAD_FILE}" 2>/dev/null || stat -c%s "${PAYLOAD_FILE}" 2>/dev/null)
echo "    Payload size: $(echo "scale=1; ${PAYLOAD_SIZE}/1048576" | bc)MB"

# 6. Assemble: stub + payload + footer
echo "==> Assembling final binary..."

if [[ ! -f "$STUB" ]]; then
    echo "ERROR: Stub binary not found at ${STUB}"
    echo "Build it first with: make stub"
    exit 1
fi

cp "${STUB}" "${OUTPUT}"
STUB_SIZE=$(stat -f%z "${OUTPUT}" 2>/dev/null || stat -c%s "${OUTPUT}" 2>/dev/null)

# Append payload
cat "${PAYLOAD_FILE}" >> "${OUTPUT}"

# Write the 24-byte footer: [offset:u64le] [size:u64le] [magic:8bytes]
python3 -c "
import struct, sys
offset = ${STUB_SIZE}
size = ${PAYLOAD_SIZE}
magic = b'CRUBY\x00\x01\x00'
footer = struct.pack('<QQ', offset, size) + magic
sys.stdout.buffer.write(footer)
" >> "${OUTPUT}"

chmod +x "${OUTPUT}"

FINAL_SIZE=$(stat -f%z "${OUTPUT}" 2>/dev/null || stat -c%s "${OUTPUT}" 2>/dev/null)
echo ""
echo "==> Done! Binary: ${OUTPUT}"
echo "    Size: $(echo "scale=1; ${FINAL_SIZE}/1048576" | bc)MB"
echo "    Run:  ./${OUTPUT} --help"
