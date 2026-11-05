#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/build"
HOST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
HOST_BINARY="$BUILD_DIR/Build/Products/Release/PiplyNativeHost"
EXTENSION_ID="${1:-}"

if [[ -z "$EXTENSION_ID" ]]; then
  print -u2 "Usage: $0 <Chrome extension ID>"
  exit 2
fi

xcodebuild -project "$ROOT_DIR/Piply.xcodeproj" -scheme PiplyNativeHost -configuration Release -derivedDataPath "$BUILD_DIR" build
mkdir -p "$HOST_DIR"
cat > "$HOST_DIR/com.example.universal_pip.json" <<JSON
{
  "name": "com.example.universal_pip",
  "description": "Piply native bridge",
  "path": "$HOST_BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

echo "Installed native host for extension $EXTENSION_ID"

