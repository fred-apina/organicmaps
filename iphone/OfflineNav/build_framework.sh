#!/bin/bash
# Links the OfflineNavEngine dynamic framework for one SDK from the engine's static libraries.
#
#   build_framework.sh <iphoneos|iphonesimulator> <products dir> <output dir>
#
# <products dir> is the folder holding the built engine libraries (lib*.a, minizip.framework and
# shaders_metal.metallib), normally <derived data>/Build/Products/Release-<sdk>.
# The result is <output dir>/OfflineNavEngine.framework.
#
# KEEP_SYMBOLS=1 in the environment skips stripping (for readable crash reports).
#
# Needs Xcode. Only the symbols listed in exports.txt are exported, and everything the framework
# does not reach is dead-stripped, so the engine's 800 MB of static libraries become about 20 MB.
set -euo pipefail

SDK="${1:?sdk: iphoneos or iphonesimulator}"
PRODUCTS="${2:?products dir}"
OUT="${3:?output dir}"
MIN_IOS="${MIN_IOS:-15.0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
case "$SDK" in
  iphoneos) TARGET="arm64-apple-ios${MIN_IOS}"; PLATFORM="iPhoneOS" ;;
  iphonesimulator) TARGET="arm64-apple-ios${MIN_IOS}-simulator"; PLATFORM="iPhoneSimulator" ;;
  *) echo "unknown sdk: $SDK" >&2; exit 64 ;;
esac

[ -f "$PRODUCTS/libmap.a" ] || { echo "missing $PRODUCTS/libmap.a: build the engine libraries first" >&2; exit 2; }
[ -f "$PRODUCTS/shaders_metal.metallib" ] || { echo "missing $PRODUCTS/shaders_metal.metallib" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FW="$OUT/OfflineNavEngine.framework"
rm -rf "$FW"
mkdir -p "$FW/Headers" "$FW/Modules" "$OUT"

COMPILE_FLAGS=(
  -x objective-c++ -std=c++23 -fobjc-arc -fmodules -stdlib=libc++
  -target "$TARGET" -isysroot "$SDKPATH" -O2
  -DRELEASE -DNDEBUG -DGLES_SILENCE_DEPRECATION
  -Wno-missing-template-arg-list-after-template-kw
  -I "$HERE" -I "$HERE/Public" -I "$ROOT" -I "$ROOT/libs" -I "$ROOT/3party/boost_headers"
  -I "$ROOT/3party/glaze/include" -I "$ROOT/3party/utfcpp/source" -I "$ROOT/3party/expat/expat/lib"
  -I "$ROOT/3party/glm" -I "$ROOT/3party/pugixml/pugixml/src"
)

OBJECTS=()
for src in "$HERE"/*.mm; do
  obj="$WORK/$(basename "${src%.mm}").o"
  xcrun clang++ "${COMPILE_FLAGS[@]}" -c "$src" -o "$obj"
  OBJECTS+=("$obj")
done

# minizip is a dynamic framework in the Organic Maps app; here its two sources go straight into this
# framework so the host app has nothing else to embed.
MINIZIP_FLAGS=(-target "$TARGET" -isysroot "$SDKPATH" -O2 -w -I "$ROOT/3party/minizip-ng" -I "$ROOT/xcode/minizip"
  -I "$ROOT" -I "$ROOT/libs")
xcrun clang -x c "${MINIZIP_FLAGS[@]}" -D_POSIX_C_SOURCE=200809L -D_BSD_SOURCE -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE \
  -c "$ROOT/3party/minizip/minizip_ng.c" -o "$WORK/minizip_ng.o"
xcrun clang++ -x c++ -std=c++23 -stdlib=libc++ "${MINIZIP_FLAGS[@]}" -c "$ROOT/3party/minizip/minizip.cpp" -o "$WORK/minizip.o"
OBJECTS+=("$WORK/minizip_ng.o" "$WORK/minizip.o")

# The libraries the Organic Maps app links, minus its own UI frameworks and minizip.
LIBS=(-ltimezone -lharfbuzz -lshaders -ldescriptions -lbsdiff -lmwm_diff -lopen_location_code -lstb_image
  -lvulkan_wrapper -lfreetype -lge0 -ltraffic -lexpat -lpugixml -ltransit -lbase -lcoding -ldrape -ltess2
  -ldrape_frontend -leditor -lgeometry -licu -lindexer -lkml -lmap -lopening_hours
  -lplatform -lrouting -lrouting_common -lsearch -lstorage -lsuccinct -lz)
SYSTEM=(-framework Foundation -framework UIKit -framework CoreGraphics -framework CoreLocation -framework Metal
  -framework MetalKit -framework QuartzCore -framework AVFoundation -framework IOKit -framework Network
  -framework CFNetwork -framework CoreVideo -framework OpenGLES -framework CoreFoundation -framework Security -framework SystemConfiguration)

xcrun clang++ -dynamiclib -target "$TARGET" -isysroot "$SDKPATH" -stdlib=libc++ -fobjc-arc -ObjC \
  -install_name "@rpath/OfflineNavEngine.framework/OfflineNavEngine" \
  -current_version 1.0.0 -compatibility_version 1.0.0 \
  -Xlinker -dead_strip -Xlinker -exported_symbols_list -Xlinker "$HERE/exports.txt" \
  -Xlinker -no_warn_duplicate_libraries \
  "${OBJECTS[@]}" -L"$PRODUCTS" -F"$PRODUCTS" "${LIBS[@]}" "${SYSTEM[@]}" \
  -o "$FW/OfflineNavEngine"
# KEEP_SYMBOLS=1 keeps function names, so crash reports can be read while debugging.
[ -n "${KEEP_SYMBOLS:-}" ] || xcrun strip -x "$FW/OfflineNavEngine"

cp "$HERE"/Public/*.h "$FW/Headers/"
cp "$HERE/module.modulemap" "$FW/Modules/module.modulemap"
cp "$PRODUCTS/shaders_metal.metallib" "$FW/shaders_metal.metallib"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>OfflineNavEngine</string>
  <key>CFBundleIdentifier</key><string>io.github.fredapina.OfflineNavEngine</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>OfflineNavEngine</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${PLATFORM}</string></array>
  <key>MinimumOSVersion</key><string>${MIN_IOS}</string>
</dict>
</plist>
PLIST

echo "built $FW ($(du -sh "$FW" | cut -f1))"
