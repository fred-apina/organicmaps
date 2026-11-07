#!/bin/bash
# Builds everything the offline_navigation Flutter plugin needs on iOS, from this checkout:
#
#   <out>/Frameworks/OfflineNavEngine.xcframework   the engine (arm64 device + arm64 simulator)
#   <out>/Resources/                                the engine's shared data files (fonts, symbols, style rules...)
#   <out>/ENGINE_COMMIT                             the commit it was built from
#
# Copy the two folders into the plugin's ios/ folder, see PUBLISHING.md of the plugin:
#   rsync -a <out>/Frameworks <out>/Resources <out>/ENGINE_COMMIT <plugin>/ios/
#
#   build_xcframework.sh [--out DIR] [--derived DIR] [--skip-libs]
#     --out DIR      where to put the result (default: ./build/offline_nav_ios)
#     --derived DIR  Xcode derived data, holds the 1.5 GB of static libraries (default: <out>/derived)
#     --skip-libs    reuse the static libraries already in --derived (only relink)
#
# Needs: Xcode with the iOS SDK and the Metal Toolchain (xcodebuild -downloadComponent MetalToolchain), and a
# checkout path WITHOUT spaces (the shader build script of the engine cannot handle them).
# The first build takes a while; later ones are incremental.
set -euo pipefail

MIN_IOS="${MIN_IOS:-15.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/build/offline_nav_ios"
DERIVED=""
SKIP_LIBS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --derived) DERIVED="$2"; shift 2 ;;
    --skip-libs) SKIP_LIBS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
DERIVED="${DERIVED:-$OUT/derived}"

case "$ROOT" in
  *" "*) echo "The checkout path contains a space: $ROOT" >&2
         echo "The engine's shader build script breaks on it. Build from a clone at a path without spaces." >&2
         exit 2 ;;
esac

# The libraries the framework links (see build_framework.sh), one Xcode scheme each, plus the Metal shaders.
SCHEMES="map routing routing_common search storage platform base coding geometry indexer editor kml drape
drape_frontend shaders descriptions bsdiff mwm_diff open_location_code stb_image vulkan_wrapper freetype ge0
traffic expat pugixml transit tess2 icu opening_hours succinct timezone harfbuzz shaders_metal"

mkdir -p "$OUT/Frameworks" "$OUT/Resources"
FRAMEWORKS=()
for SDK in iphoneos iphonesimulator; do
  case "$SDK" in
    iphoneos) DESTINATION='generic/platform=iOS' ;;
    iphonesimulator) DESTINATION='generic/platform=iOS Simulator' ;;
  esac
  PRODUCTS="$DERIVED/$SDK/Build/Products/Release-$SDK"

  if [ -z "$SKIP_LIBS" ]; then
    for SCHEME in $SCHEMES; do
      echo "== $SDK: $SCHEME"
      (cd "$ROOT" && xcodebuild -workspace xcode/omim.xcworkspace -scheme "$SCHEME" -configuration Release \
        -sdk "$SDK" -destination "$DESTINATION" -derivedDataPath "$DERIVED/$SDK" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES LLVM_LTO=NO IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        build > "$DERIVED/$SDK-$SCHEME.log" 2>&1) || { echo "FAILED: see $DERIVED/$SDK-$SCHEME.log" >&2; exit 1; }
    done
  fi

  "$HERE/build_framework.sh" "$SDK" "$PRODUCTS" "$OUT/frameworks-$SDK"
  FRAMEWORKS+=(-framework "$OUT/frameworks-$SDK/OfflineNavEngine.framework")
done

rm -rf "$OUT/Frameworks/OfflineNavEngine.xcframework"
xcodebuild -create-xcframework "${FRAMEWORKS[@]}" -output "$OUT/Frameworks/OfflineNavEngine.xcframework"

# The shared data files. The same ones the Organic Maps app bundles, without the base world maps (72 MB, which
# the plugin downloads on demand) and without the app's own UI resources.
rm -rf "$OUT/Resources"
mkdir -p "$OUT/Resources"
(
  cd "$ROOT/data"
  cp -R fonts symbols countries-strings sound-strings "$OUT/Resources/"
  cp categories.txt categories_brands.txt categories_cuisines.txt classificator.txt colors.txt countries.json \
     drules_default.bin drules_outdoors.bin drules_vehicle.bin editor.config icudt78l.dat packed_polygons.bin \
     patterns.txt synonyms.txt transit_colors.txt types.txt "$OUT/Resources/"
)

git -C "$ROOT" rev-parse HEAD > "$OUT/ENGINE_COMMIT"
echo
echo "Done: $OUT"
du -sh "$OUT/Frameworks/OfflineNavEngine.xcframework" "$OUT/Resources"
