#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
DERIVED_DIR="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/apps"
BUILT_APP_NAME="Piply.app"
APP_NAME="Piply.app"
SIGNING_IDENTITY="${PIPLY_SIGNING_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  print -u2 "Apple Development署名が見つかりません。画面収録の許可をビルド間で維持するには署名証明書が必要です。"
  print -u2 "PIPLY_SIGNING_IDENTITY に署名IDを指定してください。"
  exit 1
fi

xcodebuild -project "$ROOT_DIR/Piply.xcodeproj" -scheme Piply -configuration Release -derivedDataPath "$DERIVED_DIR" build
xcodebuild -project "$ROOT_DIR/Piply.xcodeproj" -scheme PiplyNativeHost -configuration Release -derivedDataPath "$DERIVED_DIR" build

mkdir -p "$OUTPUT_DIR"
ditto "$DERIVED_DIR/Build/Products/Release/$BUILT_APP_NAME" "$OUTPUT_DIR/$APP_NAME"
mkdir -p "$OUTPUT_DIR/$APP_NAME/Contents/MacOS"
cp "$DERIVED_DIR/Build/Products/Release/PiplyNativeHost" "$OUTPUT_DIR/$APP_NAME/Contents/MacOS/PiplyNativeHost"
chmod +x "$OUTPUT_DIR/$APP_NAME/Contents/MacOS/PiplyNativeHost"

codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$OUTPUT_DIR/$APP_NAME/Contents/MacOS/PiplyNativeHost"
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$OUTPUT_DIR/$APP_NAME"

echo "Built: $OUTPUT_DIR/$APP_NAME"
echo "Signed with: $SIGNING_IDENTITY"
