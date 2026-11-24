#!/usr/bin/env bash
set -euo pipefail

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
ARCH="arm64"
MIN_IOS="15.0"
BUILD_DIR="build"
OUT_DYLIB="${BUILD_DIR}/SideStoreTranslator.dylib"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "[1/4] Compiling SwiftUITextBridge.swift..."
xcrun -sdk iphoneos swiftc \
  -target ${ARCH}-apple-ios${MIN_IOS} \
  -sdk "${SDK}" \
  -parse-as-library \
  -emit-object \
  -O \
  Sources/SwiftUITextBridge.swift \
  -o "${BUILD_DIR}/SwiftUITextBridge.o"

echo "[2/4] Compiling SideStoreTranslator.mm..."
xcrun -sdk iphoneos clang++ \
  -arch ${ARCH} \
  -isysroot "${SDK}" \
  -miphoneos-version-min=${MIN_IOS} \
  -std=c++17 \
  -fobjc-arc \
  -O2 \
  -c Sources/SideStoreTranslator.mm \
  -o "${BUILD_DIR}/SideStoreTranslator.o"

echo "[3/4] Linking SideStoreTranslator.dylib with embedded zh-Hans.min.json..."
xcrun -sdk iphoneos clang++ \
  -arch ${ARCH} \
  -isysroot "${SDK}" \
  -miphoneos-version-min=${MIN_IOS} \
  -dynamiclib \
  -install_name @rpath/SideStoreTranslator.dylib \
  -Wl,-sectcreate,__TEXT,__st_json,Resources/zh-Hans.min.json \
  -framework Foundation \
  -framework UIKit \
  -framework CoreFoundation \
  -framework SwiftUI \
  "${BUILD_DIR}/SwiftUITextBridge.o" \
  "${BUILD_DIR}/SideStoreTranslator.o" \
  -o "${OUT_DYLIB}"

echo "[4/4] Signing dylib..."
if command -v ldid >/dev/null 2>&1; then
  ldid -S "${OUT_DYLIB}"
else
  codesign --force --sign - "${OUT_DYLIB}"
fi

echo "Done! Output ready at: ${OUT_DYLIB}"
