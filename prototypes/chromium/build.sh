#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CEF_ROOT="$(python3 fetch-cef.py)"
BUILD="$PWD/.build"
APP_NAME="Vane Chromium Prototype"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
WRAPPER="$BUILD/cef/wrapper/libcef_dll_wrapper.a"

cmake -S . -B "$BUILD/cef" -G 'Unix Makefiles' -DCEF_ROOT="$CEF_ROOT" -DPROJECT_ARCH=arm64
cmake --build "$BUILD/cef" --target libcef_dll_wrapper --parallel 8
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

COMMON=(-std=c++20 -arch arm64 -mmacosx-version-min=26.0 -I "$CEF_ROOT" -I "$PWD" -DCEF_USE_SANDBOX)
xcrun clang++ "${COMMON[@]}" -fobjc-arc -c Engine.mm -o "$BUILD/Engine.o"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macos26.0 -parse-as-library \
  -import-objc-header Bridge.h Shell.swift "$BUILD/Engine.o" "$WRAPPER" \
  -lc++ -framework Cocoa -framework IOSurface -o "$CONTENTS/MacOS/$APP_NAME"
xcrun clang++ "${COMMON[@]}" Helper.cc "$WRAPPER" \
  -framework Cocoa -framework IOSurface -o "$BUILD/Helper"

python3 - "$CONTENTS" "$APP_NAME" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

contents, name = Path(sys.argv[1]), sys.argv[2]
identifier = "io.github.notnaki.vane.chromium-prototype"
common = dict(CFBundlePackageType="APPL", CFBundleShortVersionString="0.1.0",
              CFBundleVersion="1", LSMinimumSystemVersion="26.0", NSHighResolutionCapable=True)
def write(path, info):
    path.write_bytes(plistlib.dumps(dict(common, **info)))
write(contents / "Info.plist", dict(CFBundleName=name, CFBundleDisplayName=name,
      CFBundleExecutable=name, CFBundleIdentifier=identifier, CFBundleIconFile="AppIcon",
      NSPrincipalClass="NSApplication", NSSupportsAutomaticGraphicsSwitching=True))
for suffix, bundle_suffix in [("", ""), (" (Alerts)", ".alerts"), (" (GPU)", ".gpu"),
                              (" (Plugin)", ".plugin"), (" (Renderer)", ".renderer")]:
    helper_name = name + " Helper" + suffix
    helper = contents / "Frameworks" / (helper_name + ".app") / "Contents"
    (helper / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(contents.parent.parent / "Helper", helper / "MacOS" / helper_name)
    write(helper / "Info.plist", dict(CFBundleName=helper_name, CFBundleExecutable=helper_name,
          CFBundleIdentifier=identifier + ".helper" + bundle_suffix, LSUIElement=True))
PY

FRAMEWORK='Chromium Embedded Framework.framework'
if [ ! -d "$CONTENTS/Frameworks/$FRAMEWORK" ]; then
  ditto "$CEF_ROOT/Release/$FRAMEWORK" "$CONTENTS/Frameworks/$FRAMEWORK"
fi
cp Resources/*.html "$CONTENTS/Resources/"
cp "$CEF_ROOT/LICENSE.txt" "$CEF_ROOT/CREDITS.html" "$CONTENTS/Resources/"
if [ -f ../../AppIcons/Prebuilt/AppIcon.icns ]; then
  cp ../../AppIcons/Prebuilt/AppIcon.icns "$CONTENTS/Resources/"
fi
codesign --force --deep --sign - "$CONTENTS/Frameworks/$FRAMEWORK"
for helper in "$CONTENTS"/Frameworks/*.app; do
  codesign --force --sign - --options runtime --entitlements entitlements.plist "$helper"
done
codesign --force --sign - --options runtime --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
