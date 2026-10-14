#!/bin/bash
# Builds build/DevSweep.app (universal arm64 + x86_64) with Command Line Tools only.
#   ./build_app.sh            # universal release build
#   ARCHS=arm64 ./build_app.sh  # faster single-arch build for development
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/DevSweep.app"
mkdir -p build

# swiftc directly: avoids depending on SwiftPM (broken in some Command Line Tools installs).
# The default SDK can be newer than the installed compiler, so try SDKs newest-first
# until one matches (override with SDK=/path/to/MacOSX.sdk).
compile() { # sdk arch
    swiftc -O -parse-as-library -target "$2-apple-macos14.0" -sdk "$1" \
        -o "build/DevSweep-$2" Sources/DevSweep/*.swift
}
SDKS=("${SDK:-$(xcrun --show-sdk-path)}")
SDKS+=($(ls -d "$(dirname "$(xcrun --show-sdk-path)")"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV))
FIRST_ARCH="${ARCHS%% *}"
for sdk in "${SDKS[@]}"; do
    if compile "$sdk" "$FIRST_ARCH" 2>build/build.log; then GOOD_SDK="$sdk"; break; fi
    echo "SDK $(basename "$sdk") didn't work with this compiler, trying next…"
done
[ -n "${GOOD_SDK:-}" ] || { cat build/build.log; exit 1; }
echo "Compiled $FIRST_ARCH with $(basename "$GOOD_SDK")"
SLICES=("build/DevSweep-$FIRST_ARCH")
for arch in $ARCHS; do
    [ "$arch" = "$FIRST_ARCH" ] && continue
    compile "$GOOD_SDK" "$arch" 2>>build/build.log || { cat build/build.log; exit 1; }
    echo "Compiled $arch"
    SLICES+=("build/DevSweep-$arch")
done

[ -f Resources/AppIcon.icns ] || { swiftc -sdk "$GOOD_SDK" -o build/make_icon scripts/make_icon/main.swift Sources/DevSweep/Theme.swift && build/make_icon "$PWD"; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/DevSweep"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Background agent for scheduled tasks, registered at runtime with SMAppService.agent(plistName:).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/com.teamnova.DevSweep.scheduler.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.teamnova.DevSweep.scheduler</string>
    <key>BundleProgram</key><string>Contents/MacOS/DevSweep</string>
    <key>ProgramArguments</key><array><string>DevSweep</string><string>--run-due-tasks</string></array>
    <key>AssociatedBundleIdentifiers</key><array><string>com.teamnova.DevSweep</string></array>
    <key>StartInterval</key><integer>900</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>10</integer>
</dict>
</plist>
AGENT

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DevSweep</string>
    <key>CFBundleDisplayName</key><string>DevSweep</string>
    <key>CFBundleIdentifier</key><string>com.teamnova.DevSweep</string>
    <key>CFBundleExecutable</key><string>DevSweep</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) TeamNova</string>
    <key>NSAppleEventsUsageDescription</key><string>DevSweep asks Finder to empty the Trash when you choose Empty Trash.</string>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY:--}" ${SIGN_IDENTITY:+--options runtime --timestamp} "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/DevSweep"))"
