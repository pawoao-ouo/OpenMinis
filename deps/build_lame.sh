#!/bin/bash
set -euo pipefail

# ============================================================================
# LAME 3.100 static library builder for iOS device and Apple Silicon Simulator
#
# Usage:
#   ./build_lame.sh [device|simulator|clean]
#
# Output:
#   deps/lame-build/iphoneos/lib/libmp3lame.a
#   deps/lame-build/iphonesimulator/lib/libmp3lame.a
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAME_VERSION="3.100"
LAME_TARBALL="lame-${LAME_VERSION}.tar.gz"
LAME_SRC_DIR="$SCRIPT_DIR/lame-${LAME_VERSION}"
IOS_DEPLOYMENT_TARGET="14.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}" >&2; exit 1; }

MODE="${1:-device}"
if [[ "$MODE" == "clean" ]]; then
    log_info "Cleaning LAME source and build artifacts..."
    rm -rf "$LAME_SRC_DIR" "$SCRIPT_DIR/lame-build"
    log_success "Clean completed"
    exit 0
fi

case "$MODE" in
    device)
        IOS_SDK_NAME="iphoneos"
        MIN_VERSION_FLAG="-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
        ;;
    simulator)
        IOS_SDK_NAME="iphonesimulator"
        MIN_VERSION_FLAG="-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
        ;;
    *)
        log_error "Unknown target '$MODE'. Use: device, simulator, or clean."
        ;;
esac

LAME_BUILD_DIR="$SCRIPT_DIR/lame-build/$IOS_SDK_NAME"
IOS_SDK="$(xcrun --sdk "$IOS_SDK_NAME" --show-sdk-path)"
CC="$(xcrun --sdk "$IOS_SDK_NAME" -f clang)"

if [[ ! -d "$LAME_SRC_DIR" ]]; then
    log_info "Downloading LAME ${LAME_VERSION}..."
    cd "$SCRIPT_DIR"
    if [[ ! -f "$LAME_TARBALL" ]]; then
        curl -fL --retry 3 --retry-delay 2 \
            "https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/${LAME_TARBALL}/download" \
            -o "$LAME_TARBALL"
    fi
    tar xzf "$LAME_TARBALL"
    rm -f "$LAME_TARBALL"
    log_success "LAME source extracted"
else
    log_info "LAME source already present, skipping download"
fi

[[ -x "$LAME_SRC_DIR/configure" ]] || log_error "Missing executable configure script in $LAME_SRC_DIR"
mkdir -p "$LAME_BUILD_DIR"

log_info "Configuring LAME ${LAME_VERSION} for ${IOS_SDK_NAME} arm64..."
cd "$LAME_BUILD_DIR"
export CC
export CFLAGS="-arch arm64 ${MIN_VERSION_FLAG} -isysroot ${IOS_SDK} -Oz -fPIC -Wno-implicit-function-declaration"
export LDFLAGS="-arch arm64 ${MIN_VERSION_FLAG} -isysroot ${IOS_SDK}"
"$LAME_SRC_DIR/configure" \
    --prefix="$LAME_BUILD_DIR" \
    --host=aarch64-apple-darwin \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    --disable-decoder \
    --disable-gtktest \
    --with-pic

log_info "Building LAME for ${IOS_SDK_NAME}..."
make -j"$(sysctl -n hw.ncpu)"
make install

LIBRARY="$LAME_BUILD_DIR/lib/libmp3lame.a"
[[ -f "$LIBRARY" ]] || log_error "Build failed — $LIBRARY not found"

log_success "LAME ${LAME_VERSION} built for ${IOS_SDK_NAME}"
printf '\n  Static library: %s\n  Headers:        %s\n' \
    "$LIBRARY" "$LAME_BUILD_DIR/include/lame/lame.h"
file "$LIBRARY"
xcrun lipo -info "$LIBRARY"
