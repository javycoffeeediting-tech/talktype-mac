#!/bin/bash
# Builds build/TalkType.app and build/TalkType.dmg. Runs on a Mac, normally on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

LLAMA_BUILD=b12173
LLAMA_SHA256=4bddb4df09a84d8181263570b6ebdd55e28eac27228804e138d43eda0c6c43a3

swift build -c release --arch arm64

APP=build/TalkType.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/rewriter" "$APP/Contents/Frameworks"

cp "$(swift build -c release --arch arm64 --show-bin-path)/TalkType" "$APP/Contents/MacOS/TalkType"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/silero-vad.bin Resources/selftest-german.wav "$APP/Contents/Resources/"

# The Whisper library, from the prebuilt package Swift fetched.
FRAMEWORK=$(find .build/artifacts -type d -path '*macos-arm64*' -name 'whisper.framework' | head -1)
[ -n "$FRAMEWORK" ] || { echo "whisper.framework not found"; exit 1; }
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"

# The app icon, at every size macOS wants.
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The llama.cpp server that runs the language model.
ARCHIVE=build/llama.tar.gz
curl -L --fail --silent --show-error -o "$ARCHIVE" "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
echo "$LLAMA_SHA256  $ARCHIVE" | shasum -a 256 -c -
mkdir -p build/llama
tar -xzf "$ARCHIVE" -C build/llama
SERVER=$(find build/llama -type f -name 'llama-server' | head -1)
[ -n "$SERVER" ] || { echo "llama-server not found"; exit 1; }
FOLDER=$(dirname "$SERVER")
cp "$SERVER" "$APP/Contents/Resources/rewriter/"
cp -a "$FOLDER"/*.dylib "$APP/Contents/Resources/rewriter/"
cp -a "$FOLDER"/*.metal "$APP/Contents/Resources/rewriter/" 2>/dev/null || true

# A stable signature, so the Microphone and Accessibility permissions survive updates. The
# certificate is a free self-signed one, kept in signing/. It proves nothing to Gatekeeper, which is
# why people still have to choose Open Anyway once.
KEYCHAIN=build/signing.keychain-db
security create-keychain -p talktype "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p talktype "$KEYCHAIN"
security import signing/talktype.p12 -k "$KEYCHAIN" -P talktype -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k talktype "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain signing/talktype.pem

IDENTITY=$(security find-certificate -c "TalkType" -Z "$KEYCHAIN" | awk '/SHA-1/ { print $NF; exit }')
sign() {
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$@"
}

find "$APP/Contents/Resources/rewriter" -type f \( -name '*.dylib' -o -name 'llama-server' \) | while read -r file; do
    sign "$file"
done
sign "$APP/Contents/Frameworks/whisper.framework"
sign --identifier app.talktype.mac "$APP"
codesign --verify --deep --strict "$APP"

hdiutil create -volname TalkType -srcfolder "$APP" -ov -format UDZO build/TalkType.dmg
echo "Built build/TalkType.dmg"
