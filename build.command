#!/bin/zsh

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR" || exit 1

clear
echo "Piply をビルドし、配布用Releaseを作成します…"
echo ""

"$SCRIPT_DIR/build.sh"
result=$?

if (( result == 0 )); then
  echo ""
  echo "配布用Releaseを作成します…"
  "$SCRIPT_DIR/scripts/package-release.sh"
  result=$?
fi

if (( result == 0 )); then
  echo ""
  echo "ビルドとReleaseの作成が完了しました。"
  echo "アプリ: $SCRIPT_DIR/apps/Piply.app"
  echo "Release: $SCRIPT_DIR/release"
  terminal_window_id="$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null)"
  if [[ -n "$terminal_window_id" ]]; then
    (sleep 0.4; osascript -e "tell application \"Terminal\" to close window id $terminal_window_id" >/dev/null 2>&1) &
  fi
  exit 0
else
  echo ""
  echo "ビルドまたはReleaseの作成に失敗しました。上のエラーを確認してください。"
fi

echo ""
read -k 1 "?何かキーを押すと閉じます…"
echo ""
exit $result
