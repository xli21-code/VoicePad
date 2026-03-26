#!/bin/bash
set -euo pipefail

# Build sherpa-onnx for macOS (arm64)
# Produces: Frameworks/sherpa-onnx/{lib,include}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build-sherpa"
FRAMEWORK_DIR="$PROJECT_DIR/Frameworks/sherpa-onnx"

if [ -d "$FRAMEWORK_DIR/lib" ] && [ -f "$FRAMEWORK_DIR/lib/libsherpa-onnx-c-api.dylib" ]; then
    echo "sherpa-onnx already built at $FRAMEWORK_DIR"
    echo "Delete $FRAMEWORK_DIR to rebuild."
    exit 0
fi

echo "=== Building sherpa-onnx for macOS arm64 ==="

# Clone if needed
if [ ! -d "$BUILD_DIR/sherpa-onnx" ]; then
    echo "Cloning sherpa-onnx..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx.git
else
    echo "Using existing sherpa-onnx clone at $BUILD_DIR/sherpa-onnx"
fi

cd "$BUILD_DIR/sherpa-onnx"

# Build shared libraries for macOS
echo "Building with cmake..."
mkdir -p build-macos
cd build-macos

cmake .. \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_CHECK=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF

cmake --build . --config Release -j $(sysctl -n hw.ncpu)

# Install to Frameworks dir
echo "Installing to $FRAMEWORK_DIR..."
mkdir -p "$FRAMEWORK_DIR/lib" "$FRAMEWORK_DIR/include"

# Copy libraries
cp -P lib/libsherpa-onnx-c-api*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libsherpa-onnx-core*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libonnxruntime*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libkaldi-native-fbank-core*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libkaldi-decoder-core*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libsherpa-onnx-kaldifst-core*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libsherpa-onnx-fstfar*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P lib/libsherpa-onnx-fst*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true
cp -P _deps/onnxruntime-src/lib/libonnxruntime*.dylib "$FRAMEWORK_DIR/lib/" 2>/dev/null || true

# Copy headers
cp ../sherpa-onnx/c-api/c-api.h "$FRAMEWORK_DIR/include/"

# Fix rpaths so dylibs can find each other
echo "Fixing library rpaths..."
cd "$FRAMEWORK_DIR/lib"
for dylib in *.dylib; do
    [ -L "$dylib" ] && continue  # skip symlinks
    install_name_tool -add_rpath @loader_path "$dylib" 2>/dev/null || true
done

echo ""
echo "=== sherpa-onnx built successfully ==="
echo "Libraries: $FRAMEWORK_DIR/lib/"
echo "Headers:   $FRAMEWORK_DIR/include/"
ls -la "$FRAMEWORK_DIR/lib/"*.dylib 2>/dev/null | head -10
