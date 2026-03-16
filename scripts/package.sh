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

# Copy top-level shared libs (bundled musl loader, libgcc_s, etc.)
for f in "${RUBY_DIR}"/lib/*.so* "${RUBY_DIR}"/lib/ld-*; do
    [[ -f "$f" ]] && cp -a "$f" "${STAGING_DIR}/lib/"
done

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
    # Check if gem exists by looking for its directory (works for cross-platform builds)
    GEM_FOUND=$(find "${RUBY_DIR}/lib/ruby/gems" -maxdepth 3 -type d -name "${GEM_NAME}-*" | head -1)
    if [[ -z "$GEM_FOUND" ]]; then
        # Try running gem install (only works for native platform)
        if "${RUBY}" --version >/dev/null 2>&1; then
            echo "    Not found, installing..."
            "${GEM_CMD}" install "${GEM_NAME}" --no-document 2>&1 | sed 's/^/    /'
        else
            echo "ERROR: gem '${GEM_NAME}' not found in ${RUBY_DIR} and cannot run gem install (cross-platform build)."
            echo "       Install the gem first inside Docker using the target Ruby."
            exit 1
        fi
    fi
    echo "    OK: ${GEM_NAME} found"
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
    # Get Ruby version - try running ruby, fall back to directory inspection
    if "${RUBY}" --version >/dev/null 2>&1; then
        RUBY_MAJOR_MINOR=$("${RUBY}" -e 'puts RUBY_VERSION.split(".")[0..1].join(".")')
    else
        # Cross-platform: infer from the gems directory name
        RUBY_MAJOR_MINOR=$(ls -1 "${RUBY_DIR}/lib/ruby/gems/" 2>/dev/null | head -1 | sed 's/\.[0-9]*$//')
    fi
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
# Determine binary format for platform-specific steps
BINARY_FORMAT_CHECK=$(file "${STAGING_DIR}/bin/ruby" | grep -o 'ELF' || true)

if [[ "$FIX_DYLIBS" == "yes" && "$BINARY_FORMAT_CHECK" != "ELF" && "$(uname -s)" == "Darwin" ]]; then
    echo "==> Fixing dylib references (macOS)..."
    "${SCRIPT_DIR}/fix-dylibs.sh" "${STAGING_DIR}"
fi

# For Linux: verify the bundled loader and runtime libs are present.
# These are baked into the Ruby installation by the Dockerfile at build time.
if [[ "$BINARY_FORMAT_CHECK" == "ELF" ]]; then
    LOADER=$(find "${STAGING_DIR}/lib" -name "ld-musl-*" -type f 2>/dev/null | head -1)
    if [[ -n "$LOADER" ]]; then
        chmod +x "$LOADER"
        echo "    Bundled musl loader: $(basename "$LOADER")"
        # List all bundled .so files
        find "${STAGING_DIR}/lib" -maxdepth 1 -name "*.so*" -type f | while read -r f; do
            echo "    Bundled lib: $(basename "$f")"
        done
    else
        echo "    WARNING: No bundled musl loader found in lib/"
        echo "             The binary may not work on non-musl Linux systems."
        echo "             Rebuild Ruby with the Dockerfile to bundle the loader."
    fi
fi

# ===================================================================
# Stage 5: Verify portability
# ===================================================================
echo "==> Verifying portability..."

# Determine binary format
BINARY_FORMAT=$(file "${STAGING_DIR}/bin/ruby" | grep -o 'ELF\|Mach-O')

if [[ "$BINARY_FORMAT" == "ELF" ]]; then
    # Linux: check with ldd (if available) or file
    if command -v ldd &>/dev/null && ldd "${STAGING_DIR}/bin/ruby" 2>&1 | grep -q "statically linked"; then
        echo "    OK: ruby is statically linked"
    elif file "${STAGING_DIR}/bin/ruby" | grep -q "statically linked"; then
        echo "    OK: ruby is statically linked"
    else
        echo "    INFO: cannot verify static linking (cross-platform build)"
    fi
    # Check .so files for non-system deps
    find "${STAGING_DIR}" -name "*.so" -type f | while read -r f; do
        if command -v readelf &>/dev/null; then
            NEEDED=$(readelf -d "$f" 2>/dev/null | grep NEEDED | grep -v 'libc\.\|libm\.\|libdl\.\|libpthread\.\|librt\.\|ld-linux' || true)
            if [[ -n "$NEEDED" ]]; then
                echo "    WARN: ${f#${STAGING_DIR}/} has deps: $NEEDED"
            fi
        fi
    done
elif [[ "$BINARY_FORMAT" == "Mach-O" ]]; then
    # macOS: check with otool
    PORTABLE=true
    NON_SYS=$(otool -L "${STAGING_DIR}/bin/ruby" 2>/dev/null | tail -n +2 | grep -v '/usr/lib/' | grep -v '/System/' || true)
    if [[ -n "$NON_SYS" ]]; then
        echo "    FAIL: bin/ruby has non-portable deps:"
        echo "$NON_SYS" | sed 's/^/          /'
        PORTABLE=false
    fi

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
        echo ""
    fi
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
    # Gem mode: set up load paths manually to avoid rubygems dependency.
    # Static Ruby builds may not have rubygems loaded by default.
    cat > "${STAGING_DIR}/entry.rb" << 'ENTRY_EOF'
# portable-cruby entry (gem mode)
root = ENV["PORTABLE_CRUBY_ROOT"]

# Cleanup handler for no-cache mode
if cleanup_dir = ENV["PORTABLE_CRUBY_CLEANUP"]
  at_exit do
    require "fileutils"
    FileUtils.rm_rf(cleanup_dir) rescue nil
  end
end

ENTRY_EOF

    # Build $LOAD_PATH entries from the actual gem directories
    cat >> "${STAGING_DIR}/entry.rb" << EOF
# Add Ruby stdlib to load path
ruby_lib = File.join(root, "lib", "ruby", "${GEM_VERSION_DIR}")
\$LOAD_PATH.unshift(ruby_lib)

# Add arch-specific stdlib
Dir.glob(File.join(ruby_lib, "*-*")).each do |arch_dir|
  \$LOAD_PATH.unshift(arch_dir) if File.directory?(arch_dir)
end

# Add gem lib directories to load path
gem_base = File.join(root, "lib", "ruby", "gems", "${GEM_VERSION_DIR}")
Dir.glob(File.join(gem_base, "gems", "*", "lib")).each do |lib_dir|
  \$LOAD_PATH.unshift(lib_dir)
end

# Add native extension directories
Dir.glob(File.join(gem_base, "extensions", "**", "*.{bundle,so}")).each do |ext|
  ext_dir = File.dirname(ext)
  \$LOAD_PATH.unshift(ext_dir) unless \$LOAD_PATH.include?(ext_dir)
end
EOF

    # Find the gem's actual exe script and inline its logic
    GEM_EXE_DIR=$(find "${RUBY_DIR}/lib/ruby/gems" -path "*/gems/${GEM_NAME}-*/exe/${ENTRY_BIN}" -type f | head -1)
    if [[ -z "$GEM_EXE_DIR" ]]; then
        GEM_EXE_DIR=$(find "${RUBY_DIR}/lib/ruby/gems" -path "*/gems/${GEM_NAME}-*/bin/${ENTRY_BIN}" -type f | head -1)
    fi

    if [[ -n "$GEM_EXE_DIR" ]]; then
        echo "" >> "${STAGING_DIR}/entry.rb"
        echo "# --- Inlined from $(basename "$GEM_EXE_DIR") ---" >> "${STAGING_DIR}/entry.rb"
        # Copy the exe, skip shebang and frozen_string_literal
        grep -v '^#!' "$GEM_EXE_DIR" | grep -v 'frozen_string_literal' | \
          sed "s|require_relative \"\.\./lib/|require \"|g" >> "${STAGING_DIR}/entry.rb"
    else
        # Fallback: try to use rubygems if available
        cat >> "${STAGING_DIR}/entry.rb" << EOF

# Fallback: load via rubygems
require 'rubygems'
ENV["GEM_HOME"] = gem_base
ENV["GEM_PATH"] = gem_base
Gem.clear_paths
gem '${GEM_NAME}'
load Gem.bin_path('${GEM_NAME}', '${ENTRY_BIN}')
EOF
    fi
fi

echo "    Entry script created (mode: ${MODE})"

# ===================================================================
# Stage 7: Compress and assemble
# ===================================================================
echo "==> Compressing payload..."
cd "${STAGING_DIR}"

# Use gzip -- universally available on all target systems (no zstd dependency).
# --no-mac-metadata avoids ._* resource fork files that confuse GNU tar on Linux.
tar czf "${PAYLOAD_FILE}" --no-mac-metadata . 2>/dev/null || \
tar czf "${PAYLOAD_FILE}" .
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

WRITE_FOOTER="${PROJECT_DIR}/build/write-footer"
if [[ ! -f "$WRITE_FOOTER" ]]; then
    echo "ERROR: write-footer not found. Run: make stub"
    exit 1
fi
"$WRITE_FOOTER" "${OUTPUT}" "${STUB_SIZE}" "${PAYLOAD_SIZE}"

chmod +x "${OUTPUT}"

FINAL_SIZE=$(stat -f%z "${OUTPUT}" 2>/dev/null || stat -c%s "${OUTPUT}" 2>/dev/null)
echo ""
echo "==> Done!"
echo "    Binary: ${OUTPUT} ($(echo "scale=1; ${FINAL_SIZE}/1048576" | bc)MB)"
echo "    Run:    ./${OUTPUT}"
