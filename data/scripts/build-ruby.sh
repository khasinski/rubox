#!/usr/bin/env bash
#
# Build a static (or mostly-static) CRuby for a given target.
#
# Usage: ./scripts/build-ruby.sh [--ruby-version VERSION] [--target TARGET] [--output DIR]
#
# Targets:
#   x86_64-linux    - Linux amd64 (via Docker + Alpine/musl)
#   aarch64-linux   - Linux arm64 (via Docker + Alpine/musl)
#   x86_64-darwin   - macOS Intel (native build)
#   aarch64-darwin  - macOS Apple Silicon (native build)
#
set -euo pipefail

RUBY_VERSION="${RUBY_VERSION:-4.0.0}"
TARGET=""
OUTPUT_DIR=""
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ruby-version) RUBY_VERSION="$2"; shift 2 ;;
        --target)       TARGET="$2"; shift 2 ;;
        --output)       OUTPUT_DIR="$2"; shift 2 ;;
        --jobs|-j)      JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Auto-detect target if not specified
if [[ -z "$TARGET" ]]; then
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$ARCH" in
        x86_64|amd64)  ARCH="x86_64" ;;
        arm64|aarch64) ARCH="aarch64" ;;
    esac
    TARGET="${ARCH}-${OS}"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="build/ruby-${RUBY_VERSION}-${TARGET}"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Support both standalone layout and gem layout (PORTABLE_RUBY_DATA_DIR)
if [[ -n "${PORTABLE_RUBY_DATA_DIR:-}" ]]; then
    DATA_DIR="$PORTABLE_RUBY_DATA_DIR"
    PROJECT_DIR="$(pwd)"
else
    DATA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    PROJECT_DIR="$DATA_DIR"
fi

echo "==> Building Ruby ${RUBY_VERSION} for ${TARGET}"
echo "    Output: ${OUTPUT_DIR}"
echo "    Jobs: ${JOBS}"

build_linux() {
    local arch="$1"
    local docker_platform=""
    case "$arch" in
        x86_64)  docker_platform="linux/amd64" ;;
        aarch64) docker_platform="linux/arm64" ;;
    esac

    echo "==> Building via Docker (Alpine/musl) for ${docker_platform}"

    docker buildx build \
        --platform "${docker_platform}" \
        --build-arg RUBY_VERSION="${RUBY_VERSION}" \
        --build-arg JOBS="${JOBS}" \
        --output "type=local,dest=${PROJECT_DIR}/${OUTPUT_DIR}" \
        -f "${DATA_DIR}/Dockerfile.ruby-build" \
        "${DATA_DIR}"
}

build_darwin() {
    echo "==> Building natively on macOS"

    local ruby_src_dir="build/src/ruby-${RUBY_VERSION}"
    local ruby_tarball="build/src/ruby-${RUBY_VERSION}.tar.gz"
    local prefix="${PROJECT_DIR}/${OUTPUT_DIR}"

    mkdir -p build/src

    # Download Ruby source
    if [[ ! -f "$ruby_tarball" ]]; then
        local major_minor="${RUBY_VERSION%.*}"
        local url="https://cache.ruby-lang.org/pub/ruby/${major_minor}/ruby-${RUBY_VERSION}.tar.gz"
        echo "==> Downloading Ruby ${RUBY_VERSION} from ${url}"
        curl -fSL -o "$ruby_tarball" "$url"
    fi

    # Extract
    if [[ ! -d "$ruby_src_dir" ]]; then
        echo "==> Extracting Ruby source"
        tar xzf "$ruby_tarball" -C build/src
    fi

    # Check for dependencies via Homebrew or system
    local openssl_dir=""
    local libyaml_dir=""
    local libffi_dir=""
    local zlib_dir=""
    local readline_dir=""

    if command -v brew &>/dev/null; then
        openssl_dir="$(brew --prefix openssl@3 2>/dev/null || true)"
        libyaml_dir="$(brew --prefix libyaml 2>/dev/null || true)"
        libffi_dir="$(brew --prefix libffi 2>/dev/null || true)"
        zlib_dir="$(brew --prefix zlib 2>/dev/null || true)"
        readline_dir="$(brew --prefix readline 2>/dev/null || true)"
    fi

    # Build flags to statically link all dependencies.
    # On macOS, ld prefers .dylib over .a when both exist in the same dir.
    # We create a staging directory with symlinks to only the .a files,
    # then point -L at that directory so the linker has no choice but to
    # use the static archives.
    local static_lib_stage="${PROJECT_DIR}/build/static-libs"
    rm -rf "$static_lib_stage"
    mkdir -p "$static_lib_stage"

    local static_ldflags="-L${static_lib_stage}"
    local static_cppflags=""

    for dep_dir in "$openssl_dir" "$zlib_dir" "$libyaml_dir" "$readline_dir" "$libffi_dir"; do
        if [[ -n "$dep_dir" && -d "$dep_dir/lib" ]]; then
            # Symlink all .a files into our staging dir
            for a in "$dep_dir"/lib/*.a; do
                [[ -f "$a" ]] && ln -sf "$a" "$static_lib_stage/"
            done
        fi
        if [[ -n "$dep_dir" && -d "$dep_dir/include" ]]; then
            static_cppflags="$static_cppflags -I$dep_dir/include"
        fi
    done

    echo "    Static lib staging dir contents:"
    ls -la "$static_lib_stage/"

    local configure_args=(
        --prefix="$prefix"
        --disable-shared
        --enable-static
        --disable-install-doc
        --disable-install-rdoc
        --disable-install-capi
        --with-static-linked-ext
        --without-gmp
    )

    # Check if Rust is available for YJIT
    if command -v rustc &>/dev/null; then
        local rust_version
        rust_version=$(rustc --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        echo "    Rust ${rust_version} found, enabling YJIT"
        configure_args+=(--enable-yjit)
    else
        echo "    No Rust found, disabling YJIT"
        configure_args+=(--disable-yjit)
    fi

    if [[ -n "$openssl_dir" ]]; then
        configure_args+=(--with-openssl-dir="$openssl_dir")
    fi
    if [[ -n "$libyaml_dir" ]]; then
        configure_args+=(--with-libyaml-dir="$libyaml_dir")
    fi
    if [[ -n "$libffi_dir" ]]; then
        configure_args+=(--with-libffi-dir="$libffi_dir")
    fi
    if [[ -n "$readline_dir" ]]; then
        configure_args+=(--with-readline-dir="$readline_dir")
    fi

    cd "$ruby_src_dir"

    if [[ ! -f Makefile ]]; then
        echo "==> Configuring Ruby"
        echo "    LDFLAGS: $static_ldflags"
        echo "    CPPFLAGS: $static_cppflags"
        LDFLAGS="$static_ldflags" \
        CPPFLAGS="$static_cppflags" \
        ./configure "${configure_args[@]}"
    fi

    echo "==> Compiling Ruby (${JOBS} jobs)"
    make -j"${JOBS}"

    echo "==> Installing Ruby to ${prefix}"
    make install

    # Verify what we built
    echo "==> Checking library dependencies..."
    otool -L "${prefix}/bin/ruby" | head -20

    cd "$PROJECT_DIR"

    echo "==> Ruby built successfully at ${prefix}"
    echo "    Binary: ${prefix}/bin/ruby"
    "${prefix}/bin/ruby" --version
}

case "$TARGET" in
    x86_64-linux|aarch64-linux)
        build_linux "${TARGET%%-*}"
        ;;
    x86_64-darwin|aarch64-darwin)
        build_darwin
        ;;
    *)
        echo "Unsupported target: $TARGET"
        echo "Supported: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin"
        exit 1
        ;;
esac

echo "==> Done. Ruby ${RUBY_VERSION} built for ${TARGET} at ${OUTPUT_DIR}"
