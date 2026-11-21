#!/usr/bin/env bash
# Builds PS Remote Play for iOS into Frameworks/VitChiaki.xcframework: chiaki-ng's library (the
# submodule in third-party/chiaki-ng), the C layer the app calls (native/shim/vitchiaki.h), and
# what they need (OpenSSL, curl, json-c, miniupnpc, nanopb, jerasure), as one static library for
# iPhones (arm64) and one for the iOS Simulator (arm64).
#
# macOS only, with Xcode, CMake, Ninja, protoc and Python 3 (nanopb's generator):
#   brew install cmake ninja protobuf
set -euo pipefail
cd "$(dirname "$0")"
NATIVE="$PWD"
ROOT="$(cd .. && pwd)"
CHIAKI="$ROOT/third-party/chiaki-ng"
BUILD="$NATIVE/build"
OUT="$ROOT/Frameworks"
MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
OPENSSL_VERSION=3.0.15
PLATFORMS="${PLATFORMS:-iphoneos iphonesimulator}"

[ -f "$CHIAKI/CMakeLists.txt" ] || git -C "$ROOT" submodule update --init third-party/chiaki-ng
# chiaki-ng's own submodules (only those the library needs)
git -C "$CHIAKI" submodule update --init --depth 1 \
  third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl

# nanopb's generator, with Python's protobuf (in its own environment: the system's Python is managed)
if [ ! -x "$BUILD/venv/bin/python3" ]; then
  python3 -m venv "$BUILD/venv"
  "$BUILD/venv/bin/pip" install --quiet "protobuf>=4.25,<7"
fi
PY="$BUILD/venv/bin/python3"
export PATH="$BUILD/venv/bin:$PATH"

# ---- OpenSSL, once per platform
openssl() {
  local sdk="$1" prefix="$BUILD/openssl-$1"
  [ -f "$prefix/lib/libcrypto.a" ] && return
  local src="$BUILD/openssl-src-$sdk"
  rm -rf "$src"
  mkdir -p "$src"
  [ -f "$BUILD/openssl-$OPENSSL_VERSION.tar.gz" ] || curl -fsSL -o "$BUILD/openssl-$OPENSSL_VERSION.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
  tar -xzf "$BUILD/openssl-$OPENSSL_VERSION.tar.gz" -C "$src" --strip-components 1
  local target flags
  if [ "$sdk" = iphoneos ]; then
    target=ios64-xcrun
    flags="-mios-version-min=$MIN_IOS"
  else
    target=iossimulator-xcrun
    flags="-arch arm64 -mios-simulator-version-min=$MIN_IOS"
  fi
  (cd "$src" && ./Configure "$target" no-shared no-tests no-engine no-async --prefix="$prefix" --openssldir="$prefix/ssl" $flags \
    && make -j"$(sysctl -n hw.ncpu)" build_libs > /dev/null && make install_dev > /dev/null)
}

for SDK in $PLATFORMS; do
  echo "== OpenSSL $OPENSSL_VERSION for $SDK"
  openssl "$SDK"
  OSSL="$BUILD/openssl-$SDK"

  echo "== chiaki-ng for $SDK"
  cmake -S "$NATIVE" -B "$BUILD/$SDK" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DPYTHON_EXECUTABLE="$PY" -DPython3_EXECUTABLE="$PY" \
    -DOPENSSL_ROOT_DIR="$OSSL" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DOPENSSL_INCLUDE_DIR="$OSSL/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$OSSL/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$OSSL/lib/libssl.a" \
    -DCMAKE_FIND_ROOT_PATH="$OSSL" \
    > "$BUILD/cmake-$SDK.log" || { tail -n 80 "$BUILD/cmake-$SDK.log"; exit 1; }
  cmake --build "$BUILD/$SDK" --target vitchiaki

  # one static library: every library built here, and OpenSSL's
  LIBS=()
  while IFS= read -r a; do LIBS+=("$a"); done < <(find "$BUILD/$SDK" -name '*.a' -not -path '*/CMakeFiles/*' | sort)
  LIBS+=("$OSSL/lib/libssl.a" "$OSSL/lib/libcrypto.a")
  printf '   %s\n' "${LIBS[@]}"
  mkdir -p "$BUILD/lib-$SDK"
  libtool -static -no_warning_for_no_symbols -o "$BUILD/lib-$SDK/libVitChiaki.a" "${LIBS[@]}"
done

# the headers Swift sees: the C layer only (no chiaki header)
INC="$BUILD/include"
rm -rf "$INC"
mkdir -p "$INC"
cp "$NATIVE/shim/vitchiaki.h" "$INC/"
cat > "$INC/module.modulemap" <<'EOF'
module VitChiaki {
    header "vitchiaki.h"
    export *
}
EOF

ARGS=()
for SDK in $PLATFORMS; do ARGS+=(-library "$BUILD/lib-$SDK/libVitChiaki.a" -headers "$INC"); done
mkdir -p "$OUT"
rm -rf "$OUT/VitChiaki.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/VitChiaki.xcframework"
ls -la "$OUT/VitChiaki.xcframework"
