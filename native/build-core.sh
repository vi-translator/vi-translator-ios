#!/usr/bin/env bash
# Builds VI Translator's shared core (vi-translator-ffi, from the desktop app's repository, at the
# commit in core.ref) into Frameworks/ViTranslatorCore.xcframework, for iPhones and the iOS
# Simulator (arm64), and copies its Swift bindings into the app (App/Core/Generated), so they always
# match the library (CI checks the committed copy is the same).
#
# macOS only, with Xcode and Rust (rustup target add aarch64-apple-ios aarch64-apple-ios-sim).
#   VIT_CORE_DIR=../vi-translator-desktop native/build-core.sh   # a checkout of your own
#   native/build-core.sh                                          # clones it at core.ref into native/build
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
REF="$(grep -v '^#' core.ref | grep -v '^$' | tail -n1)"
SRC="${VIT_CORE_DIR:-}"
if [ -z "$SRC" ]; then
  SRC="$ROOT/native/build/core-src"
  if [ ! -d "$SRC/.git" ]; then
    git clone --quiet https://github.com/vi-translator/vi-translator-desktop.git "$SRC"
  fi
  git -C "$SRC" fetch --quiet origin "$REF" 2>/dev/null || git -C "$SRC" fetch --quiet origin
  git -C "$SRC" checkout --quiet "$REF"
fi
echo "== vi-translator-core from $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?'))"

# the same iOS version for Rust and the core's C parts (aws-lc, QuickJS), as its own CI does
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/native/build/core-target}"
(cd "$SRC" && cargo build -p vi-translator-ffi --release --target aarch64-apple-ios \
  && cargo build -p vi-translator-ffi --release --target aarch64-apple-ios-sim \
  && cargo build -p vi-translator-ffi --release \
  && cargo run -p vi-translator-ffi --release --features bindgen --bin uniffi-bindgen -- \
       generate --library "$CARGO_TARGET_DIR/release/libvi_translator_ffi.dylib" --language swift --out-dir "$ROOT/native/build/core-swift")

INC="$ROOT/native/build/core-include"
rm -rf "$INC"
mkdir -p "$INC"
cp "$ROOT/native/build/core-swift/vi_translator_ffiFFI.h" "$INC/"
cp "$ROOT/native/build/core-swift/vi_translator_ffiFFI.modulemap" "$INC/module.modulemap"
mkdir -p "$ROOT/Frameworks"
rm -rf "$ROOT/Frameworks/ViTranslatorCore.xcframework"
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libvi_translator_ffi.a" -headers "$INC" \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libvi_translator_ffi.a" -headers "$INC" \
  -output "$ROOT/Frameworks/ViTranslatorCore.xcframework"
mkdir -p "$ROOT/App/Core/Generated"
cp "$ROOT/native/build/core-swift/ViTranslatorCore.swift" "$ROOT/App/Core/Generated/ViTranslatorCore.swift"
ls -la "$ROOT/Frameworks/ViTranslatorCore.xcframework"
