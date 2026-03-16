#!/usr/bin/env bash
#
# Package a Ruby gem or Gemfile-based app into a single self-extracting binary.
#
# Modes:
#   Gem mode:     --gem NAME --entry BIN
#   Gemfile mode: --gemfile PATH --entry BIN
#
# Usage:
#   # Single gem
#   ./scripts/package.sh --ruby-dir build/ruby-4.0.0-aarch64-darwin \
#     --gem herb --output build/herb
#
#   # Gemfile-based app
#   ./scripts/package.sh --ruby-dir build/ruby-4.0.0-aarch64-darwin \
#     --gemfile /path/to/Gemfile --entry my_app --output build/my_app
#
set -euo pipefail

RUBY_DIR=""
GEM_NAME=""
GEMFILE=""
ENTRY_BIN=""
OUTPUT=""
STUB=""
PRUNE_LEVEL="default"  # none, default, aggressive
KEEP_GEMS=""
REMOVE_GEMS=""
FIX_DYLIBS="yes"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ruby-dir)     RUBY_DIR="$2"; shift 2 ;;
        --gem)          GEM_NAME="$2"; shift 2 ;;
        --gemfile)      GEMFILE="$2"; shift 2 ;;
        --entry)        ENTRY_BIN="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        --stub)         STUB="$2"; shift 2 ;;
        --prune)        PRUNE_LEVEL="$2"; shift 2 ;;
        --keep-gems)    KEEP_GEMS="$2"; shift 2 ;;
        --remove-gems)  REMOVE_GEMS="$2"; shift 2 ;;
        --no-fix-dylibs) FIX_DYLIBS="no"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$RUBY_DIR" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 --ruby-dir DIR --output FILE (--gem NAME | --gemfile PATH) [--entry BIN]"
    exit 1
fi
if [[ -z "$GEM_NAME" && -z "$GEMFILE" ]]; then
    echo "ERROR: Must specify --gem or --gemfile"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUBY_DIR="$(cd "$RUBY_DIR" && pwd)"

# Defaults
ENTRY_BIN="${ENTRY_BIN:-$GEM_NAME}"
STUB="${STUB:-${PROJECT_DIR}/build/stub}"
RUBY="${RUBY_DIR}/bin/ruby"
GEM_CMD="${RUBY_DIR}/bin/gem"

STAGING_DIR=$(mktemp -d)
PAYLOAD_FILE=$(mktemp)
trap 'rm -rf "$STAGING_DIR" "$PAYLOAD_FILE"' EXIT

MODE="gem"
[[ -n "$GEMFILE" ]] && MODE="gemfile"

echo "==> Packaging (mode: ${MODE}, entry: ${ENTRY_BIN})"
echo "    Ruby: ${RUBY_DIR}"

# ===================================================================
# Stage 1: Copy Ruby
# ===================================================================
echo "==> Copying Ruby..."
mkdir -p "${STAGING_DIR}/bin"
cp "${RUBY_DIR}/bin/ruby" "${STAGING_DIR}/bin/ruby"
chmod +x "${STAGING_DIR}/bin/ruby"

mkdir -p "${STAGING_DIR}/lib"
cp -a "${RUBY_DIR}/lib/ruby" "${STAGING_DIR}/lib/ruby"

# ===================================================================
# Stage 2: Install gems (gem mode) or bundle (gemfile mode)
# ===================================================================
if [[ "$MODE" == "gemfile" ]]; then
    echo "==> Installing gems via Bundler (standalone mode)..."
    GEMFILE_ABS="$(cd "$(dirname "$GEMFILE")" && pwd)/$(basename "$GEMFILE")"
    GEMFILE_DIR="$(dirname "$GEMFILE_ABS")"

    # Ensure bundler is available
    if [[ ! -f "${RUBY_DIR}/bin/bundle" ]]; then
        "${GEM_CMD}" install bundler --no-document 2>&1 | tail -1
    fi

    BUNDLE="${RUBY_DIR}/bin/bundle"
    BUNDLE_DIR="${STAGING_DIR}/bundle"
    mkdir -p "$BUNDLE_DIR"

    # Run bundle install --standalone
    # This creates a self-contained bundle with a bundler/setup.rb
    cd "$GEMFILE_DIR"
    BUNDLE_PATH="$BUNDLE_DIR" \
    BUNDLE_GEMFILE="$GEMFILE_ABS" \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_STANDALONE=true \
    "$BUNDLE" install --standalone --jobs 4 2>&1 | sed 's/^/    /'
    cd "$PROJECT_DIR"

    echo "    Checking standalone bundle..."
    if [[ -f "$BUNDLE_DIR/bundler/setup.rb" ]]; then
        echo "    OK: standalone setup.rb found"
    else
        # Standalone setup might be elsewhere
        SETUP_RB=$(find "$BUNDLE_DIR" -name "setup.rb" -path "*/bundler/*" | head -1)
        if [[ -n "$SETUP_RB" ]]; then
            echo "    OK: standalone setup at ${SETUP_RB#${STAGING_DIR}/}"
        else
            echo "    WARNING: standalone setup.rb not found, gems may not load correctly"
        fi
    fi
else
    echo "==> Gem '${GEM_NAME}' should already be installed in Ruby dir"
    if ! "${RUBY}" -e "require '${GEM_NAME}'" 2>/dev/null; then
        echo "    Not found, installing..."
        "${GEM_CMD}" install "${GEM_NAME}" --no-document 2>&1 | sed 's/^/    /'
    fi
    echo "    OK: ${GEM_NAME} available"
fi

# ===================================================================
# Stage 3: Prune
# ===================================================================
echo "==> Pruning (level: ${PRUNE_LEVEL})..."

# Always: remove gem cache, build artifacts, docs
rm -rf "${STAGING_DIR}/lib/ruby/gems"/*/cache
find "${STAGING_DIR}" -name "*.o" -delete 2>/dev/null || true
find "${STAGING_DIR}" \( -name "doc" -o -name "ri" -o -name ".rdoc" \) -type d | xargs rm -rf 2>/dev/null || true
# Remove include/ dir (C headers, never needed at runtime)
rm -rf "${STAGING_DIR}"/lib/ruby/gems/*/extensions/*/include 2>/dev/null || true

if [[ "$PRUNE_LEVEL" != "none" ]]; then
    # Remove test/spec dirs from gems
    find "${STAGING_DIR}/lib/ruby/gems" \
        \( -name "test" -o -name "spec" -o -name "tests" -o -name "specs" \) \
        -type d | xargs rm -rf 2>/dev/null || true

    # Remove sig/ directories (RBS type signatures)
    find "${STAGING_DIR}/lib/ruby/gems" -name "sig" -type d | xargs rm -rf 2>/dev/null || true

    # Remove C source from installed gems
    find "${STAGING_DIR}/lib/ruby/gems" \( -name "*.c" -o -name "*.h" \) -type f -delete 2>/dev/null || true
    find "${STAGING_DIR}/lib/ruby/gems" -name "Makefile" -type f -delete 2>/dev/null || true

    # Remove .bundle files for Ruby versions we don't need
    RUBY_MAJOR_MINOR=$("${RUBY}" -e 'puts RUBY_VERSION.split(".")[0..1].join(".")')
    echo "    Keeping native extensions for Ruby ${RUBY_MAJOR_MINOR} only"
    # Find versioned .bundle dirs like herb/3.3/, herb/3.4/, etc.
    find "${STAGING_DIR}/lib/ruby/gems" -type d -regex '.*/[0-9]\.[0-9]$' | while read -r ver_dir; do
        ver=$(basename "$ver_dir")
        if [[ "$ver" != "$RUBY_MAJOR_MINOR" ]]; then
            rm -rf "$ver_dir"
        fi
    done

    # Apply prune list
    PRUNE_LIST="${SCRIPT_DIR}/prune-list.conf"
    if [[ -f "$PRUNE_LIST" ]]; then
        while IFS= read -r gem_pattern; do
            # Skip comments and empty lines
            [[ "$gem_pattern" =~ ^#.*$ || -z "$gem_pattern" ]] && continue
            gem_pattern=$(echo "$gem_pattern" | tr -d '[:space:]')

            # Check if this gem should be kept
            if [[ -n "$KEEP_GEMS" ]] && echo "$KEEP_GEMS" | grep -qw "$gem_pattern"; then
                continue
            fi

            # Remove from gems directory
            find "${STAGING_DIR}/lib/ruby/gems" -maxdepth 3 -type d -name "${gem_pattern}-*" | while read -r d; do
                echo "    Pruning gem: $(basename "$d")"
                rm -rf "$d"
            done

            # Remove from specifications
            find "${STAGING_DIR}/lib/ruby/gems" -name "${gem_pattern}-*.gemspec" -delete 2>/dev/null || true

            # Remove from extensions
            find "${STAGING_DIR}/lib/ruby/gems" -path "*/extensions/*/${gem_pattern}-*" -type d | xargs rm -rf 2>/dev/null || true

            # Remove from stdlib (lib/ruby/X.Y.Z/)
            for stdlib_dir in "${STAGING_DIR}"/lib/ruby/[0-9]*/; do
                rm -rf "${stdlib_dir}/${gem_pattern}" 2>/dev/null || true
                rm -f "${stdlib_dir}/${gem_pattern}.rb" 2>/dev/null || true
            done
        done < "$PRUNE_LIST"
    fi

    # Remove extra gems specified by user
    if [[ -n "$REMOVE_GEMS" ]]; then
        IFS=',' read -ra EXTRA_REMOVE <<< "$REMOVE_GEMS"
        for gem_name in "${EXTRA_REMOVE[@]}"; do
            gem_name=$(echo "$gem_name" | tr -d '[:space:]')
            find "${STAGING_DIR}/lib/ruby/gems" -maxdepth 3 -type d -name "${gem_name}-*" | while read -r d; do
                echo "    Pruning extra: $(basename "$d")"
                rm -rf "$d"
            done
        done
    fi

    # Remove fiddle (links to Homebrew libffi, rarely needed)
    if [[ -z "$KEEP_GEMS" ]] || ! echo "$KEEP_GEMS" | grep -qw "fiddle"; then
        find "${STAGING_DIR}" -path "*fiddle*" -delete 2>/dev/null || true
    fi
fi

STAGED_SIZE=$(du -sm "${STAGING_DIR}" | cut -f1)
echo "    Staged size after pruning: ${STAGED_SIZE}MB"

# ===================================================================
# Stage 4: Fix dylib references (macOS)
# ===================================================================
if [[ "$(uname -s)" == "Darwin" && "$FIX_DYLIBS" == "yes" ]]; then
    echo "==> Fixing dylib references..."
    "${SCRIPT_DIR}/fix-dylibs.sh" "${STAGING_DIR}"
fi

# ===================================================================
# Stage 5: Verify portability
# ===================================================================
echo "==> Verifying portability..."
PORTABLE=true

# Check the ruby binary
NON_SYS=$(otool -L "${STAGING_DIR}/bin/ruby" 2>/dev/null | tail -n +2 | grep -v '/usr/lib/' | grep -v '/System/' || true)
if [[ -n "$NON_SYS" ]]; then
    echo "    FAIL: bin/ruby has non-portable deps:"
    echo "$NON_SYS" | sed 's/^/          /'
    PORTABLE=false
fi

# Check all .bundle/.dylib files
find "${STAGING_DIR}" -type f \( -name "*.bundle" -o -name "*.dylib" \) ! -path "*/DWARF/*" | while read -r f; do
    NON_SYS=$(otool -L "$f" 2>/dev/null | tail -n +2 | grep -v '/usr/lib/' | grep -v '/System/' | grep -v '@loader_path' || true)
    if [[ -n "$NON_SYS" ]]; then
        echo "    FAIL: ${f#${STAGING_DIR}/}"
        echo "$NON_SYS" | sed 's/^/          /'
        PORTABLE=false
    fi
done

if [[ "$PORTABLE" == "false" ]]; then
    echo ""
    echo "WARNING: Non-portable dependencies detected."
    echo "         The binary may not work on other machines."
    echo "         Use --no-fix-dylibs to skip auto-fixing, or manually resolve."
    echo ""
fi

# ===================================================================
# Stage 6: Create entry script
# ===================================================================
echo "==> Creating entry script..."

GEM_VERSION_DIR=$(ls -1 "${STAGING_DIR}/lib/ruby/gems/" 2>/dev/null | head -1)

if [[ "$MODE" == "gemfile" ]]; then
    # Gemfile mode: use standalone bundle
    SETUP_RB_REL=$(find "${STAGING_DIR}/bundle" -name "setup.rb" -path "*/bundler/*" 2>/dev/null | head -1)
    SETUP_RB_REL="${SETUP_RB_REL#${STAGING_DIR}/}"

    cat > "${STAGING_DIR}/entry.rb" << EOF
# portable-cruby entry (gemfile mode)
root = ENV["PORTABLE_CRUBY_ROOT"]

# Cleanup handler for no-cache mode
if cleanup_dir = ENV["PORTABLE_CRUBY_CLEANUP"]
  at_exit { require "fileutils"; FileUtils.rm_rf(cleanup_dir) rescue nil }
end

# Load standalone bundle
require File.join(root, "${SETUP_RB_REL}")

# Run the entry point
load File.join(root, "bundle", "bin", "${ENTRY_BIN}")
EOF
else
    # Gem mode: use rubygems
    cat > "${STAGING_DIR}/entry.rb" << EOF
# portable-cruby entry (gem mode)
root = ENV["PORTABLE_CRUBY_ROOT"]

# Cleanup handler for no-cache mode
if cleanup_dir = ENV["PORTABLE_CRUBY_CLEANUP"]
  at_exit { require "fileutils"; FileUtils.rm_rf(cleanup_dir) rescue nil }
end

# Point rubygems at our bundled gems
gem_dir = File.join(root, "lib", "ruby", "gems", "${GEM_VERSION_DIR}")
ENV["GEM_HOME"] = gem_dir
ENV["GEM_PATH"] = gem_dir
Gem.clear_paths

require 'rubygems'
gem '${GEM_NAME}'
load Gem.bin_path('${GEM_NAME}', '${ENTRY_BIN}')
EOF
fi

echo "    Entry script created (mode: ${MODE})"

# ===================================================================
# Stage 7: Compress and assemble
# ===================================================================
echo "==> Compressing payload..."
cd "${STAGING_DIR}"

if command -v zstd &>/dev/null; then
    tar cf - . | zstd -19 -T0 > "${PAYLOAD_FILE}"
else
    echo "    (install zstd for ~30% better compression)"
    tar czf "${PAYLOAD_FILE}" .
fi
cd "${PROJECT_DIR}"

PAYLOAD_SIZE=$(stat -f%z "${PAYLOAD_FILE}" 2>/dev/null || stat -c%s "${PAYLOAD_FILE}" 2>/dev/null)
echo "    Payload: $(echo "scale=1; ${PAYLOAD_SIZE}/1048576" | bc)MB"

echo "==> Assembling binary..."

if [[ ! -f "$STUB" ]]; then
    echo "ERROR: Stub not found at ${STUB}. Run: make stub"
    exit 1
fi

cp "${STUB}" "${OUTPUT}"
STUB_SIZE=$(stat -f%z "${OUTPUT}" 2>/dev/null || stat -c%s "${OUTPUT}" 2>/dev/null)

cat "${PAYLOAD_FILE}" >> "${OUTPUT}"

python3 -c "
import struct, sys
offset = ${STUB_SIZE}
size = ${PAYLOAD_SIZE}
magic = b'CRUBY\x00\x01\x00'
sys.stdout.buffer.write(struct.pack('<QQ', offset, size) + magic)
" >> "${OUTPUT}"

chmod +x "${OUTPUT}"

FINAL_SIZE=$(stat -f%z "${OUTPUT}" 2>/dev/null || stat -c%s "${OUTPUT}" 2>/dev/null)
echo ""
echo "==> Done!"
echo "    Binary: ${OUTPUT} ($(echo "scale=1; ${FINAL_SIZE}/1048576" | bc)MB)"
echo "    Run:    ./${OUTPUT}"
