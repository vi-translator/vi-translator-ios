# The PS Remote Play library for iOS: chiaki-ng's lib (the submodule in third-party/chiaki-ng,
# pinned to a release, as in the Android app) and VI Translator's small C layer over it
# (shim/vitchiaki.c, the counterpart of the Android app's JNI layer). Built by build-chiaki.sh on
# macOS, once for iPhones and once for the iOS Simulator, against OpenSSL built for each.
cmake_minimum_required(VERSION 3.22)
project(vit-native C CXX)

set(CHIAKI_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_CLI OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_GUI OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_SETSU OFF CACHE STRING "" FORCE)
set(CHIAKI_ENABLE_ANDROID OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_BOREALIS OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_FFMPEG_DECODER OFF CACHE STRING "" FORCE)
set(CHIAKI_ENABLE_PI_DECODER OFF CACHE STRING "" FORCE)
set(CHIAKI_ENABLE_SPEEX OFF CACHE STRING "" FORCE)
set(CHIAKI_LIB_ENABLE_OPUS OFF CACHE BOOL "" FORCE)
set(CHIAKI_LIB_OPENSSL_EXTERNAL_PROJECT OFF CACHE BOOL "" FORCE)
set(CHIAKI_LIB_JSONC_EXTERNAL_PROJECT ON CACHE BOOL "" FORCE)
set(CHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT ON CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_STEAM_SHORTCUT OFF CACHE BOOL "" FORCE)
set(CHIAKI_ENABLE_STEAMDECK_NATIVE OFF CACHE STRING "" FORCE)
set(CHIAKI_USE_SYSTEM_JERASURE OFF CACHE STRING "" FORCE)
set(CHIAKI_USE_SYSTEM_NANOPB OFF CACHE STRING "" FORCE)
set(CHIAKI_USE_SYSTEM_CURL OFF CACHE STRING "" FORCE)

# curl (chiaki-ng's submodule, for Remote Play over the internet, not used here): HTTP only, with
# OpenSSL, and none of the build machine's optional libraries (they're for macOS, not iOS)
set(CURL_USE_LIBPSL OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBSSH2 OFF CACHE BOOL "" FORCE)
set(CURL_ZLIB OFF CACHE STRING "" FORCE)
set(CURL_BROTLI OFF CACHE STRING "" FORCE)
set(CURL_ZSTD OFF CACHE STRING "" FORCE)
set(USE_LIBIDN2 OFF CACHE BOOL "" FORCE)
set(USE_NGHTTP2 OFF CACHE BOOL "" FORCE)
set(USE_APPLE_IDN OFF CACHE BOOL "" FORCE)
set(CURL_USE_OPENSSL ON CACHE BOOL "" FORCE)

# Not the build machine's pkg-config: its libraries are for macOS, not iOS (json-c and miniupnpc
# are built for iOS from source). IGNORE: found, and false.
set(PKG_CONFIG_EXECUTABLE IGNORE CACHE FILEPATH "" FORCE)
set(libevent_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libevent" CACHE PATH "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third-party/chiaki-ng chiaki-ng)

add_library(vitchiaki STATIC shim/vitchiaki.c)
target_include_directories(vitchiaki PUBLIC shim)
target_link_libraries(vitchiaki chiaki-lib)

# Remote Play over the internet (holepunch.c, not used by the app) waits on its sockets with
# libevent, except on Android, where it uses plain select(): that way on iOS too (only this file;
# it has nothing else for Android), so libevent isn't needed.
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/../third-party/chiaki-ng/lib/src/remote/holepunch.c
        TARGET_DIRECTORY chiaki-lib PROPERTIES COMPILE_DEFINITIONS "__ANDROID__=1")

# The game's sound (Opus) and the CPU H.264 decoder (FFmpeg's), both built by build-chiaki.sh:
# the shim decodes with them; their libraries go into the one static library with chiaki's.
target_include_directories(vitchiaki PRIVATE ${VIT_OPUS_DIR}/include ${VIT_FFMPEG_DIR}/include)
