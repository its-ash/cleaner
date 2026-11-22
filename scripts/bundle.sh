#!/usr/bin/env bash
# Build Cleaner.app: the SwiftUI front end plus the Rust `cleaner-engine` helper.
#
#   scripts/bundle.sh            -> build/Cleaner.app
#   also builds build/Cleaner-<version>-macos.zip with Cleaner.app and INSTALL.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Cleaner.app"
VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"

echo "==> Building Rust engine (release)"
cargo build --release --manifest-path "$ROOT/Cargo.toml" --bin cleaner-engine

echo "==> Building Swift app (release)"
swift build -c release --package-path "$ROOT/app"
SWIFT_BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_BIN/Cleaner" "$APP/Contents/MacOS/Cleaner"
cp "$ROOT/target/release/cleaner-engine" "$APP/Contents/MacOS/cleaner-engine"
sed "s/__VERSION__/$VERSION/g" "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/app/Resources/Cleaner.sdef" "$APP/Contents/Resources/Cleaner.sdef"

# iconutil wants Apple's file names; the source set is named by pixel size.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="$ROOT/app/Resources/AppIcon.iconset"
for pt in 16 32 128 256 512; do
  cp "$SRC/AppIcon-$pt.png" "$ICONSET/icon_${pt}x${pt}.png"
  cp "$SRC/AppIcon-$((pt * 2)).png" "$ICONSET/icon_${pt}x${pt}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/MacOS/cleaner-engine"
codesign --force --sign - "$APP"

echo "==> Packaging"
DIST="$ROOT/build/dist"
ZIP="$ROOT/build/Cleaner-$VERSION-macos.zip"
rm -rf "$DIST" "$ZIP"
mkdir -p "$DIST"
ditto "$APP" "$DIST/Cleaner.app"
cp "$ROOT/INSTALL.txt" "$DIST/INSTALL.txt"
ditto -c -k "$DIST" "$ZIP"

# Register the Services menu item and URL scheme with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "==> Done: $APP ($VERSION)"
