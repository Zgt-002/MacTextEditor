#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="MacTextEditor"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.cache/clang" "$ROOT_DIR/.cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/clang"
export SDKROOT="$SDK_PATH"

swift build -c release \
    --disable-sandbox \
    --sdk "$SDK_PATH" \
    --cache-path "$ROOT_DIR/.cache/swiftpm" \
    --scratch-path "$ROOT_DIR/.build" \
    --manifest-cache local

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/ThirdPartyLicenses"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Vendor/scintilla/License.txt" "$APP_DIR/Contents/Resources/ThirdPartyLicenses/Scintilla.txt"
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
