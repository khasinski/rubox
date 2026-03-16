#!/usr/bin/env bash
#
# bundle-linux-libs.sh - Copy required shared libraries into a staging dir.
# Runs inside Docker (Alpine) to resolve and copy .so files.
#
# Usage: Run via Docker:
#   docker run --rm -v /path/to/staging:/staging -v /path/to/ruby:/opt/ruby alpine:3.21 \
#     sh -c "apk add ... && /staging/scripts/bundle-linux-libs.sh /opt/ruby /staging"
#
set -euo pipefail

RUBY_DIR="$1"
STAGING_DIR="$2"
LIB_DIR="${STAGING_DIR}/lib/dylibs"
mkdir -p "$LIB_DIR"

echo "Bundling shared libraries for Linux..."

# Collect all shared libs needed by the ruby binary and all .so gem extensions
LIBS_NEEDED=""

# From ruby binary
LIBS_NEEDED="$LIBS_NEEDED $(ldd "$RUBY_DIR/bin/ruby" 2>/dev/null | grep '=>' | awk '{print $3}')"

# From all .so files in gems
find "$STAGING_DIR/lib/ruby/gems" -name "*.so" -type f 2>/dev/null | while read -r f; do
    ldd "$f" 2>/dev/null | grep '=>' | awk '{print $3}'
done | sort -u | while read -r lib; do
    LIBS_NEEDED="$LIBS_NEEDED $lib"
done

# Copy unique libs, skip the dynamic linker itself
for lib in $(echo "$LIBS_NEEDED" | tr ' ' '\n' | sort -u); do
    [[ -z "$lib" ]] && continue
    basename_lib=$(basename "$lib")

    # Skip the musl dynamic linker (ld-musl-*.so.1) - it's the system loader
    case "$basename_lib" in
        ld-musl-*|ld-linux-*) continue ;;
    esac

    if [[ -f "$lib" && ! -f "$LIB_DIR/$basename_lib" ]]; then
        echo "  Bundling: $basename_lib"
        cp "$lib" "$LIB_DIR/$basename_lib"
    fi
done

echo "Bundled libraries:"
ls -la "$LIB_DIR/"
