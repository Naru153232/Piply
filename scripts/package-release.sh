#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_SOURCE="$ROOT_DIR/apps/Piply.app"
DIST_EXTENSION="$ROOT_DIR/dist/ChromeExtension"
RELEASE_ROOT="$ROOT_DIR/release"
VERSION="$(/usr/bin/plutil -extract version raw "$ROOT_DIR/ChromeExtension/manifest.json")"
PACKAGE_NAME="Piply-$VERSION"
PACKAGE_DIR="$RELEASE_ROOT/$PACKAGE_NAME"
ARCHIVE_PATH="$RELEASE_ROOT/$PACKAGE_NAME.zip"

if [[ ! -d "$APP_SOURCE" ]]; then
  print -u2 "apps/Piply.app がありません。先に ./build.sh を実行してください。"
  exit 1
fi

/usr/bin/env node "$ROOT_DIR/scripts/build-chrome-extension.mjs"

/bin/rm -rf "$PACKAGE_DIR"
/bin/mkdir -p "$PACKAGE_DIR"
/usr/bin/ditto "$APP_SOURCE" "$PACKAGE_DIR/Piply.app"
/usr/bin/ditto "$DIST_EXTENSION" "$PACKAGE_DIR/ChromeExtension"

# A local Apple Development signature exposes the certificate holder's name,
# email address, and Team ID. Removing it before re-signing is important:
# overwriting alone can leave the old certificate bytes in the executable.
APP_EXECUTABLE="$PACKAGE_DIR/Piply.app/Contents/MacOS/Piply"
HOST_EXECUTABLE="$PACKAGE_DIR/Piply.app/Contents/MacOS/PiplyNativeHost"
/usr/bin/codesign --remove-signature "$HOST_EXECUTABLE"
/usr/bin/codesign --remove-signature "$PACKAGE_DIR/Piply.app"

# Release binaries can also contain the local account name in source paths.
/usr/bin/strip -S -x "$APP_EXECUTABLE"
/usr/bin/strip -S -x "$HOST_EXECUTABLE"

/usr/bin/codesign --force --sign - "$HOST_EXECUTABLE"
/usr/bin/codesign --force --sign - "$PACKAGE_DIR/Piply.app"

/bin/cp "$ROOT_DIR/README.md" "$PACKAGE_DIR/README.md"
/bin/rm -f "$ARCHIVE_PATH"
(
  cd "$RELEASE_ROOT"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$PACKAGE_NAME.zip" "$PACKAGE_NAME"
)

echo "Created: $PACKAGE_DIR"
echo "Created: $ARCHIVE_PATH"
echo "The packaged app uses an ad-hoc signature and contains no developer certificate identity."

