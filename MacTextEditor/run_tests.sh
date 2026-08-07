#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
TEST_BINARY="$ROOT_DIR/.build/core-tests"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.cache/clang" "$ROOT_DIR/.build"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export SDKROOT="$SDK_PATH"

swiftc \
    -sdk "$SDK_PATH" \
    -module-cache-path "$ROOT_DIR/.cache/clang" \
    "$ROOT_DIR/Sources/MacTextEditor/Core.swift" \
    "$ROOT_DIR/Sources/MacTextEditor/ByteStore.swift" \
    "$ROOT_DIR/Sources/MacTextEditor/IncrementalTextDecoder.swift" \
    "$ROOT_DIR/Sources/MacTextEditor/EditorDocument.swift" \
    "$ROOT_DIR/Tests/CoreTests.swift" \
    -framework AppKit \
    -o "$TEST_BINARY"

"$TEST_BINARY"
