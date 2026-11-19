#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
ASSETS_DIR="$ROOT_DIR/assets"
OUT_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/installer/build/mac"
PKG_OUT="$OUT_DIR/OmniFlow-macOS-Installer.pkg"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAC_DIR/Info.plist" 2>/dev/null || echo '1.0.0')"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "==> Building Intel (x86_64) release binary..."
(cd "$MAC_DIR" && swift build -c release --arch x86_64)
echo "==> Building Apple Silicon (arm64) release binary..."
(cd "$MAC_DIR" && swift build -c release --arch arm64)
# Restore default .build/release symlink to native host architecture
(cd "$MAC_DIR" && swift build -c release)

ARM_BIN="$MAC_DIR/.build/arm64-apple-macosx/release/OmniFlowMac"
X64_BIN="$MAC_DIR/.build/x86_64-apple-macosx/release/OmniFlowMac"

# Prepare shared app shell (Info.plist + AppIcon.icns — only bundled once!)
COMMON_ROOT="$WORK_DIR/root_common"
mkdir -p "$COMMON_ROOT/Applications/OmniFlow.app/Contents/MacOS" \
         "$COMMON_ROOT/Applications/OmniFlow.app/Contents/Resources"
cp "$MAC_DIR/Info.plist" "$COMMON_ROOT/Applications/OmniFlow.app/Contents/Info.plist"
cp "$MAC_DIR/AppIcon.icns" "$COMMON_ROOT/Applications/OmniFlow.app/Contents/Resources/AppIcon.icns"

# Prepare stripped arm64 executable slice
ARM_ROOT="$WORK_DIR/root_arm64"
mkdir -p "$ARM_ROOT/Applications/OmniFlow.app/Contents/MacOS"
strip -r -u -x "$ARM_BIN" -o "$ARM_ROOT/Applications/OmniFlow.app/Contents/MacOS/OmniFlowMac"
chmod 755 "$ARM_ROOT/Applications/OmniFlow.app/Contents/MacOS/OmniFlowMac"

# Prepare stripped x86_64 executable slice
X64_ROOT="$WORK_DIR/root_x86_64"
mkdir -p "$X64_ROOT/Applications/OmniFlow.app/Contents/MacOS"
strip -r -u -x "$X64_BIN" -o "$X64_ROOT/Applications/OmniFlow.app/Contents/MacOS/OmniFlowMac"
chmod 755 "$X64_ROOT/Applications/OmniFlow.app/Contents/MacOS/OmniFlowMac"
xattr -cr "$COMMON_ROOT" "$ARM_ROOT" "$X64_ROOT" 2>/dev/null || true

# Scripts (shared preinstall/postinstall to safely close running app and remove quarantine)
SCRIPTS_PRE="$WORK_DIR/scripts_pre"
SCRIPTS_POST="$WORK_DIR/scripts_post"
mkdir -p "$SCRIPTS_PRE" "$SCRIPTS_POST"

cat > "$SCRIPTS_PRE/preinstall" <<'EOF'
#!/bin/bash
pkill -x OmniFlowMac >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$SCRIPTS_PRE/preinstall"

cat > "$SCRIPTS_POST/postinstall" <<'EOF'
#!/bin/bash
APP="/Applications/OmniFlow.app"
chmod 755 "$APP/Contents/MacOS/OmniFlowMac" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$SCRIPTS_POST/postinstall"

echo "==> Building component packages..."
cat > "$WORK_DIR/comp_common.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key><true/>
        <key>BundleIsRelocatable</key><false/>
        <key>BundleIsVersionChecked</key><true/>
        <key>BundleOverwriteAction</key><string>upgrade</string>
        <key>RootRelativeBundlePath</key><string>Applications/OmniFlow.app</string>
    </dict>
</array>
</plist>
PLIST

pkgbuild --root "$COMMON_ROOT" \
         --component-plist "$WORK_DIR/comp_common.plist" \
         --scripts "$SCRIPTS_PRE" \
         --identifier "com.lee.omniflow.common" \
         --version "$VERSION" \
         --install-location "/" \
         "$WORK_DIR/omniflow-common.pkg"

pkgbuild --root "$ARM_ROOT" \
         --scripts "$SCRIPTS_POST" \
         --identifier "com.lee.omniflow.arm64" \
         --version "$VERSION" \
         --install-location "/" \
         "$WORK_DIR/omniflow-arm64.pkg"

pkgbuild --root "$X64_ROOT" \
         --scripts "$SCRIPTS_POST" \
         --identifier "com.lee.omniflow.x86_64" \
         --version "$VERSION" \
         --install-location "/" \
         "$WORK_DIR/omniflow-x86_64.pkg"

# Embed compressed 9KB circular GitHub avatar in Welcome & Conclusion HTML
AVATAR_B64="$(base64 < "$ASSETS_DIR/github_avatar.jpg" | tr -d '\n')"
RES_DIR="$WORK_DIR/resources"
mkdir -p "$RES_DIR"

cat > "$RES_DIR/Welcome.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
    margin: 0;
    padding: 8px 6px;
    font-size: 13px;
    line-height: 1.55;
    color: #1d1d1f;
  }
  .card {
    background: rgba(120, 120, 128, 0.10);
    border: 1px solid rgba(120, 120, 128, 0.22);
    border-radius: 12px;
    padding: 14px 16px;
    margin: 12px 0;
  }
  .author-row {
    display: flex;
    align-items: center;
    gap: 12px;
    text-decoration: none;
    color: inherit;
    padding: 10px 14px;
    border-radius: 12px;
    background: rgba(10, 132, 255, 0.10);
    border: 1px solid rgba(10, 132, 255, 0.28);
  }
  .avatar {
    width: 44px;
    height: 44px;
    border-radius: 50%;
    object-fit: cover;
    border: 1.5px solid rgba(10, 132, 255, 0.65);
    flex-shrink: 0;
  }
  .gh-name {
    font-size: 14px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .gh-handle {
    font-size: 12px;
    color: #0a84ff;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .pill {
    display: inline-block;
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 999px;
    background: rgba(48, 209, 88, 0.16);
    color: #1f8b3d;
    margin-top: 6px;
  }
  h2 { margin: 0 0 6px; font-size: 17px; }
  ul { margin: 6px 0 0 18px; padding: 0; }
  li { margin: 3px 0; }
  @media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; }
    .card { background: rgba(255,255,255,0.06); border-color: rgba(255,255,255,0.12); }
    .gh-handle { color: #64d2ff; }
    .pill { color: #30d158; background: rgba(48,209,88,0.18); }
  }
</style>
</head>
<body>
  <h2>OmniFlow for macOS · 安装向导</h2>
  <p>跨系统键鼠共享、屏幕边缘传送带、剪贴板同步、多网卡与 USB-C 点对点直连客户端。</p>
  <div class="pill">⚡ 自动芯片识别 / Auto Arch: Apple Silicon (arm64) &amp; Intel (x86_64)</div>

  <div class="card">
    <strong>本安装包特性 / Highlights：</strong>
    <ul>
      <li>安装时自动检测当前 Mac 是 <b>Apple Silicon (M 系列)</b> 还是 <b>Intel 芯片</b>，仅写入对应原生架构。</li>
      <li>内置中 / 英文实时切换（中 | EN）、双向 TLS 1.3 配对与可选防飘移三指拖移。</li>
    </ul>
  </div>

  <a class="author-row" href="https://github.com/KSLengYu">
    <img class="avatar" src="data:image/jpeg;base64,${AVATAR_B64}" alt="KSLengYu"/>
    <div>
      <div class="gh-name">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.11.79-.25.79-.56v-1.97c-3.2.7-3.87-1.54-3.87-1.54-.52-1.32-1.27-1.68-1.27-1.68-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.18 1.76 1.18 1.02 1.76 2.68 1.25 3.34.96.1-.75.4-1.25.73-1.54-2.56-.29-5.24-1.28-5.24-5.68 0-1.25.45-2.28 1.18-3.08-.12-.29-.51-1.47.11-3.06 0 0 .96-.31 3.16 1.18.92-.26 1.9-.38 2.87-.38.97 0 1.95.13 2.87.38 2.2-1.49 3.16-1.18 3.16-1.18.62 1.59.23 2.77.11 3.06.73.8 1.18 1.83 1.18 3.08 0 4.41-2.69 5.38-5.25 5.67.41.35.78 1.05.78 2.12v3.15c0 .31.21.67.8.56A11.51 11.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>
        <span>楞宇</span>
      </div>
      <div class="gh-handle">@KSLengYu · https://github.com/KSLengYu ↗</div>
    </div>
  </a>
</body>
</html>
HTML

cat > "$RES_DIR/Conclusion.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
    margin: 0; padding: 8px 6px; font-size: 13px; line-height: 1.55; color: #1d1d1f;
  }
  .author-row {
    display: flex; align-items: center; gap: 12px; text-decoration: none; color: inherit;
    padding: 10px 14px; border-radius: 12px; margin-top: 14px;
    background: rgba(10, 132, 255, 0.10); border: 1px solid rgba(10, 132, 255, 0.28);
  }
  .avatar { width: 40px; height: 40px; border-radius: 50%; object-fit: cover; border: 1.5px solid rgba(10,132,255,0.65); }
  .gh-handle { font-size: 12px; color: #0a84ff; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  @media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; }
    .gh-handle { color: #64d2ff; }
  }
</style>
</head>
<body>
  <h2 style="margin:0 0 6px;font-size:17px;">OmniFlow 安装完成 / Installation Complete</h2>
  <p>已根据本机芯片架构自动安装原生版本到 <code>/Applications/OmniFlow.app</code>，现在可在「应用程序」中直接打开 OmniFlow。</p>
  <a class="author-row" href="https://github.com/KSLengYu">
    <img class="avatar" src="data:image/jpeg;base64,${AVATAR_B64}" alt="KSLengYu"/>
    <div>
      <div style="font-weight:600;">楞宇 · OmniFlow</div>
      <div class="gh-handle">@KSLengYu · https://github.com/KSLengYu ↗</div>
    </div>
  </a>
</body>
</html>
HTML

cat > "$WORK_DIR/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>OmniFlow</title>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <welcome file="Welcome.html" mime-type="text/html"/>
    <conclusion file="Conclusion.html" mime-type="text/html"/>

    <script>
        function isAppleSilicon() {
            try {
                return system.sysctl('hw.optional.arm64') == 1;
            } catch (e) {
                return false;
            }
        }
    </script>

    <choices-outline>
        <line choice="choice-common"/>
        <line choice="choice-arm64"/>
        <line choice="choice-x86_64"/>
    </choices-outline>

    <choice id="choice-common" title="OmniFlow Application Bundle" enabled="false" selected="true">
        <pkg-ref id="com.lee.omniflow.common"/>
    </choice>
    <choice id="choice-arm64" title="OmniFlow Native Engine (Apple Silicon arm64)"
            visible="isAppleSilicon()"
            enabled="isAppleSilicon()"
            selected="isAppleSilicon()">
        <pkg-ref id="com.lee.omniflow.arm64"/>
    </choice>
    <choice id="choice-x86_64" title="OmniFlow Native Engine (Intel x86_64)"
            visible="!isAppleSilicon()"
            enabled="!isAppleSilicon()"
            selected="!isAppleSilicon()">
        <pkg-ref id="com.lee.omniflow.x86_64"/>
    </choice>

    <pkg-ref id="com.lee.omniflow.common" version="$VERSION" onConclusion="none">omniflow-common.pkg</pkg-ref>
    <pkg-ref id="com.lee.omniflow.arm64" version="$VERSION" onConclusion="none">omniflow-arm64.pkg</pkg-ref>
    <pkg-ref id="com.lee.omniflow.x86_64" version="$VERSION" onConclusion="none">omniflow-x86_64.pkg</pkg-ref>
</installer-gui-script>
XML

echo "==> Synthesizing universal architecture-detecting .pkg installer..."
productbuild --distribution "$WORK_DIR/Distribution.xml" \
             --package-path "$WORK_DIR" \
             --resources "$RES_DIR" \
             "$PKG_OUT"

ls -lh "$PKG_OUT"
echo "==> Verifying architecture choice detection on current machine ($(uname -m)):"
installer -showChoicesXML -pkg "$PKG_OUT" -target / | grep -E '<key>choiceIdentifier</key>|<string>choice-|<key>choiceIsSelected</key>|<integer>' || true
echo "==> Done: $PKG_OUT"
