#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
INST_PKG_DIR="$ROOT_DIR/installer/mac/OmniFlowInstaller"
ASSETS_DIR="$ROOT_DIR/assets"
OUT_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/installer/build/mac"
DMG_OUT="$OUT_DIR/OmniFlow-macOS-Installer.dmg"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAC_DIR/Info.plist" 2>/dev/null || echo '1.0.0')"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "==> Building OmniFlow app binary (x86_64 + arm64)..."
(cd "$MAC_DIR" && swift build -c release --arch x86_64)
(cd "$MAC_DIR" && swift build -c release --arch arm64)
# Restore default .build/release symlink to native host architecture
(cd "$MAC_DIR" && swift build -c release)

ARM_BIN="$MAC_DIR/.build/arm64-apple-macosx/release/OmniFlowMac"
X64_BIN="$MAC_DIR/.build/x86_64-apple-macosx/release/OmniFlowMac"

echo "==> Building OmniFlow Installer GUI (universal x86_64 + arm64)..."
(cd "$INST_PKG_DIR" && swift build -c release --arch x86_64)
(cd "$INST_PKG_DIR" && swift build -c release --arch arm64)
(cd "$INST_PKG_DIR" && swift build -c release)

INST_ARM_BIN="$INST_PKG_DIR/.build/arm64-apple-macosx/release/OmniFlowInstaller"
INST_X64_BIN="$INST_PKG_DIR/.build/x86_64-apple-macosx/release/OmniFlowInstaller"

make_payload_bundle() {
    local arch="$1"
    local src_bin="$2"
    local dst_app="$3"
    mkdir -p "$dst_app/Contents/MacOS" "$dst_app/Contents/Resources"
    cp "$MAC_DIR/Info.plist" "$dst_app/Contents/Info.plist"
    cp "$MAC_DIR/AppIcon.icns" "$dst_app/Contents/Resources/AppIcon.icns"
    strip -r -u -x "$src_bin" -o "$dst_app/Contents/MacOS/OmniFlowMac"
    chmod 755 "$dst_app/Contents/MacOS/OmniFlowMac"
    xattr -cr "$dst_app" 2>/dev/null || true
    codesign --force --deep --sign - "$dst_app" >/dev/null
}

DMG_STAGE="$WORK_DIR/dmg_stage"
INSTALLER_APP="$DMG_STAGE/OmniFlow Installer.app"
mkdir -p "$INSTALLER_APP/Contents/MacOS" \
         "$INSTALLER_APP/Contents/Resources/Payload"

cp "$INST_PKG_DIR/Info.plist" "$INSTALLER_APP/Contents/Info.plist"
cp "$MAC_DIR/AppIcon.icns" "$INSTALLER_APP/Contents/Resources/AppIcon.icns"
cp "$ASSETS_DIR/github_avatar.jpg" "$INSTALLER_APP/Contents/Resources/avatar.jpg"
sips -s format png "$MAC_DIR/AppIcon.icns" -z 256 256 --out "$INSTALLER_APP/Contents/Resources/icon.png" >/dev/null

# Universal fat binary for OmniFlowInstaller GUI itself
lipo -create "$INST_ARM_BIN" "$INST_X64_BIN" -output "$INSTALLER_APP/Contents/MacOS/OmniFlowInstaller"
strip -r -u -x "$INSTALLER_APP/Contents/MacOS/OmniFlowInstaller" || true
chmod 755 "$INSTALLER_APP/Contents/MacOS/OmniFlowInstaller"

echo "==> Preparing arm64 & x86_64 app payloads inside OmniFlow Installer.app..."
make_payload_bundle "arm64" "$ARM_BIN" "$INSTALLER_APP/Contents/Resources/Payload/OmniFlow-arm64.app"
make_payload_bundle "x86_64" "$X64_BIN" "$INSTALLER_APP/Contents/Resources/Payload/OmniFlow-x86_64.app"

xattr -cr "$INSTALLER_APP" 2>/dev/null || true
codesign --force --deep --sign - "$INSTALLER_APP" >/dev/null

echo "==> Packaging compressed DMG: $DMG_OUT ..."
rm -f "$DMG_OUT" "$OUT_DIR/OmniFlow-macOS-Installer.pkg"
hdiutil create -volname "OmniFlow Installer v${VERSION}" \
               -srcfolder "$DMG_STAGE" \
               -ov -format UDZO -imagekey zlib-level=9 \
               "$DMG_OUT" >/dev/null

ls -lh "$DMG_OUT"
echo "==> Verifying universal installer binary architectures:"
file "$INSTALLER_APP/Contents/MacOS/OmniFlowInstaller"
echo "==> Done: $DMG_OUT"
