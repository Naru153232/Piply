#!/bin/zsh

set -u

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR" || exit 1

clear
current_version="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
change_type="${1:-patch}"

echo "Piply のバージョンを更新します。"
echo "現在のバージョン: $current_version"
echo "更新方法: $change_type"
echo ""
read "answer?実行しますか？ [y/N]: "

if [[ "$answer" != [yY] ]]; then
  echo "更新をキャンセルしました。"
  echo ""
  read -k 1 "?何かキーを押すと閉じます…"
  echo ""
  exit 0
fi

echo ""
if /usr/bin/env node "$SCRIPT_DIR/scripts/bump-version.mjs" "$change_type"; then
  result=0
  echo ""
  echo "バージョン更新が完了しました。"
else
  result=$?
  echo ""
  echo "バージョン更新に失敗しました。上のエラーを確認してください。"
fi

echo ""
read -k 1 "?何かキーを押すと閉じます…"
echo ""
exit $result
