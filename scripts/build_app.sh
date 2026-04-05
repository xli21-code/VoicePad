#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR=$(pwd)

echo "=== Building VoicePad.app ==="

# 1. Build release binary
echo "Building release..."
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/VoicePad"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

# 2. Create .app bundle structure
DIST="$PROJECT_DIR/dist"
APP="$DIST/VoicePad.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Frameworks"
mkdir -p "$CONTENTS/Resources"

# 3. Copy binary
cp "$BINARY" "$CONTENTS/MacOS/VoicePad"

# 4. Copy frameworks (sherpa-onnx dylibs) — use symlink to avoid duplicating onnxruntime (~33MB)
SHERPA_LIB="$PROJECT_DIR/Frameworks/sherpa-onnx/lib"
cp "$SHERPA_LIB/libsherpa-onnx-c-api.dylib" "$CONTENTS/Frameworks/"
cp "$SHERPA_LIB/libonnxruntime.1.23.2.dylib" "$CONTENTS/Frameworks/"
ln -sf "libonnxruntime.1.23.2.dylib" "$CONTENTS/Frameworks/libonnxruntime.dylib"

# 5. Strip debug symbols to reduce binary size
echo "Stripping symbols..."
strip -x "$CONTENTS/MacOS/VoicePad"
strip -x "$CONTENTS/Frameworks/libsherpa-onnx-c-api.dylib"
strip -x "$CONTENTS/Frameworks/libonnxruntime.1.23.2.dylib"

# 6. Fix rpath references — binary should find dylibs in Frameworks/
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/VoicePad" 2>/dev/null || true

# 7. Write Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VoicePad</string>
    <key>CFBundleIdentifier</key>
    <string>com.voicepad.app</string>
    <key>CFBundleName</key>
    <string>VoicePad</string>
    <key>CFBundleDisplayName</key>
    <string>VoicePad</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoicePad needs microphone access to record your voice for transcription.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
</dict>
</plist>
PLIST

# 8. Copy app icon
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/"
fi

# 9. Sign with VoicePad Dev certificate (preserves TCC permissions across rebuilds)
echo "Signing..."
# Sign embedded frameworks first (skip symlinks), then the app bundle
for dylib in "$CONTENTS/Frameworks/"*.dylib; do
    [ -L "$dylib" ] && continue
    codesign --force --sign "VoicePad Dev" "$dylib"
done
codesign --force --sign "VoicePad Dev" "$APP"

echo ""
echo "=== Done ==="
echo "App bundle: $APP"
echo "Run: open $APP"
