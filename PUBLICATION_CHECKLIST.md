# 公開前チェックリスト

## 公開リポジトリへ含めてよいもの

- `Piply/`、`NativeHost/`、`ChromeExtension/` のソースコード
- `tests/` のテストコードとテスト用HTML
- `Piply.xcodeproj`（ただし `xcuserdata` を除く）
- `project.yml`、`build.sh`、`build.command`
- `scripts/` のビルド・配布スクリプト
- `README.md`、このチェックリスト、`.gitignore`

## 公開リポジトリへ含めないもの

- `build/`：ビルド中間生成物。ローカルの絶対パスを含む場合があります。
- `apps/`：ローカルのApple Development証明書で署名されたアプリ。署名者の氏名、メールアドレス、Team IDを含みます。
- `output/`：録画、スクリーンショット、操作確認画像。画面内に個人情報が映る可能性があります。
- `xcuserdata/`、`*.xcuserstate`：Xcodeの利用者固有データ。
- `dist/`、`release/`：再生成できる配布物。ソース管理ではなくリリース添付ファイルとして扱います。
- `.env*`、証明書、秘密鍵、プロビジョニングプロファイル。

上記は `.gitignore` で除外されています。すでにGitへ追加済みのファイルがある場合、`.gitignore` だけでは追跡を解除できないため、公開前にGitの追跡対象一覧も確認してください。

## 配布物の作成

1. `./build.sh` でアプリをビルドします。
2. `./scripts/package-release.sh` を実行します。
3. `release/Piply-<version>.zip` を配布します。

配布スクリプトは、配布コピーから開発者署名とローカルパスを含むデバッグ情報を削除し、個人情報を含まないアドホック署名を付けます。元の `apps/Piply.app` は変更しません。

## 一般公開前に別途決めること

- 現在のBundle IDとNative Messaging Host名は `com.example` です。正式公開時は、所有している一意の識別子へ関連箇所をまとめて変更してください。
- ソースを第三者に利用・改変してもらう場合は、LICENSEファイルと採用ライセンスを決めてください。
- macOSのGatekeeper警告を避けるには、配布者のDeveloper IDによる署名とAppleの公証が必要です。この場合、署名には配布者情報が含まれることを理解したうえで行ってください。

