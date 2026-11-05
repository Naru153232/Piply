#!/bin/zsh

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR" || exit 1

clear
echo "Piply をビルドします…"
echo ""

if "$SCRIPT_DIR/build.sh"; then
  echo ""
  echo "ビルドが完了しました。"
  echo "出力先: $SCRIPT_DIR/apps/Piply.app"
  terminal_window_id="$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null)"
  if [[ -n "$terminal_window_id" ]]; then
    (sleep 0.4; osascript -e "tell application \"Terminal\" to close window id $terminal_window_id" >/dev/null 2>&1) &
  fi
  exit 0
else
  result=$?
  echo ""
  echo "ビルドに失敗しました。上のエラーを確認してください。"
fi

echo ""
read -k 1 "?何かキーを押すと閉じます…"
echo ""
exit $result
