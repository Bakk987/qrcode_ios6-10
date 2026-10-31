#!/usr/bin/env bash
# Builds QRScanner.ipa (armv7 for iOS 6+, arm64 for iOS 7+) on Linux or macOS.
#   TOOLCHAIN : dir with clang, ld, lipo, ldid (cctools/ld64-based iOS toolchain)
#   SDK       : path to an iPhoneOS SDK (tested with iPhoneOS10.3.sdk)
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN=${TOOLCHAIN:-/home/claude/tc/linux/iphone/bin}
SDK=${SDK:-/home/claude/sdk-patched/iPhoneOS10.3.sdk}
APP=QRScanner
BUILD=build
PAYLOAD=$BUILD/Payload/$APP.app

CC="$TOOLCHAIN/clang"
rm -rf "$BUILD"; mkdir -p "$PAYLOAD" "$BUILD/obj"

SOURCES_M=(src/main.m src/AppDelegate.m src/ScannerViewController.m)
SOURCES_C=(src/QRDecode.c quirc/quirc.c quirc/decode.c quirc/identify.c quirc/version_db.c)
FRAMEWORKS=(-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore
            -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox)

slices=()
for spec in "armv7:6.0" "arm64:7.0"; do
  arch=${spec%%:*}; min=${spec##*:}
  TARGET=(-target "$arch-apple-ios$min" -isysroot "$SDK" -miphoneos-version-min="$min")
  objs=()
  for f in "${SOURCES_M[@]}"; do
    o="$BUILD/obj/$arch-$(basename "${f%.*}").o"
    "$CC" "${TARGET[@]}" -fobjc-arc -Os -Wall -Wno-deprecated-declarations -Isrc -c "$f" -o "$o"
    objs+=("$o")
  done
  for f in "${SOURCES_C[@]}"; do
    o="$BUILD/obj/$arch-c-$(basename "${f%.*}").o"
    "$CC" "${TARGET[@]}" -O2 -std=gnu99 -Wno-everything -Isrc -c "$f" -o "$o"
    objs+=("$o")
  done
  # Link without -fobjc-arc so the driver doesn't look for libarclite (not needed for iOS 6+).
  "$CC" "${TARGET[@]}" -fuse-ld="$TOOLCHAIN/ld" -dead_strip "${objs[@]}" "${FRAMEWORKS[@]}" \
        -o "$BUILD/$APP-$arch" 2> >(grep -v "built for iOS Simulator\|is deprecated" >&2)
  "$TOOLCHAIN/strip" -x "$BUILD/$APP-$arch"
  slices+=("$BUILD/$APP-$arch")
done

"$TOOLCHAIN/lipo" -create "${slices[@]}" -output "$PAYLOAD/$APP"
cp Info.plist "$PAYLOAD/Info.plist"
printf 'APPL????' > "$PAYLOAD/PkgInfo"
cp assets/*.png "$PAYLOAD/"
cp quirc/LICENSE "$PAYLOAD/quirc-LICENSE.txt"

# Ad-hoc ("fake") signature: runs on jailbroken devices with AppSync;
# re-sign with your own certificate (e.g. Sideloadly) for stock devices.
cat > "$BUILD/ent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>com.example.qrscanner</string>
  <key>get-task-allow</key><true/>
</dict></plist>
EOF
"$TOOLCHAIN/ldid" -S"$BUILD/ent.plist" "$PAYLOAD/$APP"

(cd "$BUILD" && rm -f ../$APP.ipa && zip -qry ../$APP.ipa Payload)
echo "Built $(pwd)/$APP.ipa"
