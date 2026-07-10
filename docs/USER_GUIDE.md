# Registry Manager v4 ユーザーガイド

学生リポジトリ管理システムの包括的な使用方法について説明します。

## 目次

1. [概要](#概要)
2. [インストールと設定](#インストールと設定)
3. [基本的な使い方](#基本的な使い方)
4. [コマンドリファレンス](#コマンドリファレンス)
5. [応用的な使用例](#応用的な使用例)
6. [トラブルシューティング](#トラブルシューティング)

## 概要

Registry Manager v4は、九州産業大学の論文執筆支援システムにおける学生リポジトリの管理を効率化するためのコマンドラインツールです。

### 主な機能

- **リポジトリ管理**: 学生リポジトリの追加・更新・削除
- **データ表示**: 様々な形式での情報表示（テーブル、CSV、JSON）
- **フィルタリング**: リポジトリタイプや保護状態による絞り込み
- **GitHub統合**: GitHub APIとの安全な統合によるデータ管理
- **データ移行**: 旧版（v1）から新版（v4）への自動移行

### 対応リポジトリタイプ

- **wr**: 週次レポート
- **ise-report**: 情報科学演習レポート
- **sotsuron**: 卒業論文・修士論文

## インストールと設定

### 必要要件

- Elixir 1.14以上
- Erlang/OTP 25以上
- GitHub APIアクセス（オプション）

### インストール

```bash
# registry_manager_v4ディレクトリに移動
cd registry_manager_v4

# 依存関係のインストール
mix deps.get

# ビルド
mix escript.build

# 実行可能ファイルの確認
ls -la registry-manager
```

### 設定

#### 1. 基本設定（~/.config/registry-manager/config.yml）

`registry-manager init` が生成します（注釈付き YAML。旧 config.json は
読み込まれないため `mv config.json config.yml` でリネームして移行）:

```yaml
github_org: smkwlab
# レジストリデータリポジトリ（owner/repo）。書き込み先のため明示必須
registry_repo: smkwlab/thesis-student-registry

# 名簿 CSV（任意。氏名解決用。未設定時は ~/.config/<github_org>/students.csv を規約として参照）
# csv_path: /path/to/students.csv
```

レジストリデータファイルはリポジトリ内の `data/registry.json` に固定です。
全設定項目は [CONFIGURATION.md](CONFIGURATION.md) を参照してください。

#### 2. 環境変数・CLI フラグによる一時上書き

設定の優先順位は **CLI フラグ > 環境変数 > 設定ファイル > デフォルト値** です。

```bash
# 環境変数での上書き（例）
export REGISTRY_MANAGER_REGISTRY_REPO="your-org/your-registry"
export REGISTRY_MANAGER_LOG_LEVEL="debug"

# CLI フラグでの上書き（全コマンド共通）
./registry-manager --registry-repo your-org/your-registry list
```

環境変数の一覧は [CONFIGURATION.md](CONFIGURATION.md) を参照してください。
GitHub 認証は `gh auth login` で行います（トークン用の設定キーはありません）。
CI など対話ログインできない環境では、`gh` CLI 自体が参照する
`GH_TOKEN` 環境変数で認証できます。

## 基本的な使い方

### 1. リポジトリ一覧の表示

```bash
# 基本的な一覧表示
./registry-manager list

# 詳細情報付きで表示
./registry-manager list --long

# JSON形式で出力
./registry-manager list --format json
```

**出力例:**
```
k21rs001-sotsuron   k21rs001  sotsuron  2025-07-08 15:51
k21rs002-wr         k21rs002  wr        2025-07-07 10:30
k21rs003-ise-report k21rs003  ise       2025-07-06 14:20
```

### 2. リポジトリの追加

```bash
# 基本的な追加（手動指定）
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron

# 自動推論による追加
./registry-manager add k21rs001-sotsuron

# ドライランモード（実際には追加しない）
./registry-manager add k21rs001-sotsuron --dry-run
```

### 3. リポジトリ情報の更新

```bash
# GitHub ユーザー名の設定
./registry-manager update k21rs001-sotsuron github_username student001

# 保護状態のマーク
./registry-manager protect k21rs001-sotsuron
```

## コマンドリファレンス

コマンドごとの詳細は `./registry-manager <command> --help` でも確認できます
（help はオプション仕様の単一ソースから生成されるため常に実装と一致します）。

### グローバルオプション

全コマンド共通で使えます:

| オプション | 短縮形 | 説明 |
|------------|--------|------|
| `--help` | `-h` | ヘルプを表示 |
| `--verbose` | `-v` | 詳細ログを表示 |
| `--registry-repo OWNER/REPO` | | registry_repo を一時的に上書き |
| `--config PATH` | `-c` | 設定ファイルのパスを上書き |
| `--org ORG` | | github_org を一時的に上書き |

コマンドに存在しないオプションや enum 外の値はパース段階でエラーになります。

### list コマンド

リポジトリ一覧を表示します。

```bash
./registry-manager list [TYPE] [OPTIONS]
```

**引数:**
- `TYPE` - フィルター対象のリポジトリタイプ（wr, ise, sotsuron, master, thesis, latex, other）

**オプション:**

| オプション | 短縮形 | 説明 |
|------------|--------|------|
| `--long` | `-l` | 詳細情報を表示 |
| `--format table\|csv\|json` | | 出力形式 |
| `--type TYPE` | `-T` | リポジトリタイプでフィルター |
| `--show-type` | | タイプ情報を表示 |
| `--show-protection` | `-p` | 保護状態を表示 |
| `--show-student-id` | `-s` | 学生IDを表示 |
| `--no-names` | | 学生名を非表示 |
| `--activity` | `-a` | リポジトリの最終活動時刻を表示 |
| `--owner-activity` | `-o` | オーナーの活動時刻を表示 |
| `--show-registry-updated` | | registry_updated_at 列を表示 |
| `--show-both-timestamps` | | リポジトリ/レジストリ両方の時刻列を表示 |
| `--no-cache` | | キャッシュを使用しない |
| `--sort name\|time` | | ソートキー（デフォルト: name）。`-t` は `--sort time` の短縮 |
| `--reverse` | `-r` | 逆順でソート |

**使用例:**
```bash
# 卒論リポジトリのみ詳細表示
./registry-manager list --type sotsuron --long

# CSV形式で全データ出力
./registry-manager list --format csv --long

# 時刻順（新しい順）で逆順表示
./registry-manager list --sort time -r

# 保護状態付きでJSON出力
./registry-manager list --format json --show-protection
```

### add コマンド

新しいリポジトリを追加します。

```bash
./registry-manager add REPO_NAME [STUDENT_ID] [TYPE] [OPTIONS]
```

**引数:**
- `REPO_NAME` - リポジトリ名（必須）
- `STUDENT_ID` - 学生ID（オプション、自動推論可能）
- `TYPE` - リポジトリタイプ（オプション、自動推論可能）

**オプション:**
- `--dry-run` - 実際には追加せず、処理内容のみ表示

**使用例:**
```bash
# 完全手動指定
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron

# 自動推論（推奨）
./registry-manager add k21rs001-sotsuron

# ドライランで確認
./registry-manager add k21rs001-sotsuron --dry-run
```

### update コマンド

既存リポジトリの情報を更新します。

```bash
./registry-manager update REPO_NAME FIELD VALUE [OPTIONS]
```

**更新可能フィールド:**
- `github_username` - GitHubユーザー名
- `repository_type` - リポジトリタイプ
- その他のカスタムフィールド

**使用例:**
```bash
./registry-manager update k21rs001-sotsuron github_username student001
./registry-manager update k21rs001-sotsuron repository_type thesis
```

### protect コマンド

リポジトリの保護状態をマークします。

```bash
./registry-manager protect REPO_NAME [OPTIONS]
```

**使用例:**
```bash
./registry-manager protect k21rs001-sotsuron
./registry-manager protect k21rs001-sotsuron --dry-run
```

### remove コマンド

リポジトリをレジストリから削除します。

```bash
./registry-manager remove REPO_NAME [OPTIONS]
```

**オプション:**
- `--dry-run` - 実際には削除せず、処理内容のみ表示
- `--delete-github-repo` - GitHub リポジトリ削除コマンドをあわせて案内

**使用例:**
```bash
./registry-manager remove k21rs001-test
./registry-manager remove k21rs001-test --dry-run
./registry-manager remove k21rs001-test --delete-github-repo
```

### cache コマンド

キャッシュ管理を行います。

```bash
./registry-manager cache SUBCOMMAND [REPO_NAME] [OPTIONS]
```

**サブコマンド:**
- `status` - キャッシュ状態の確認
- `clear` - キャッシュのクリア
- `refresh` - キャッシュの再取得

リポジトリ名を指定すると、そのリポジトリのキャッシュだけを対象にします。

**使用例:**
```bash
./registry-manager cache status
./registry-manager cache clear
./registry-manager cache status k21rs001-sotsuron
./registry-manager cache clear k21rs001-sotsuron
```

### migrate コマンド

データ移行を管理します。

```bash
./registry-manager migrate SUBCOMMAND [OPTIONS]
```

**サブコマンド:**
- `status` - 移行状態の確認
- `dry-run` - 移行のシミュレーション
- `execute` - 実際の移行実行

**使用例:**
```bash
# 移行状態の確認
./registry-manager migrate status

# 移行のドライラン
./registry-manager migrate dry-run

# 実際の移行実行
./registry-manager migrate execute
```

### validate コマンド

データの整合性を検証します。

```bash
./registry-manager validate [REPO_NAME] [OPTIONS]
```

**使用例:**
```bash
# 全データの検証
./registry-manager validate

# 特定リポジトリの検証
./registry-manager validate k21rs001-sotsuron

# JSON 形式で出力
./registry-manager validate --format json

# 件別の検証結果を表示
./registry-manager validate --verbose
```

レガシー形式のエントリが検出された場合、移行は `migrate` コマンドで行います。

### pr-status コマンド

各リポジトリの Pull Request 状態を表示します。

```bash
./registry-manager pr-status [TYPE] [OPTIONS]
```

**オプション:**

| オプション | 短縮形 | 説明 |
|------------|--------|------|
| `--format table\|csv\|json` | | 出力形式 |
| `--type TYPE` | `-T` | リポジトリタイプでフィルター |
| `--state open\|closed\|all` | | PR 状態でフィルター |
| `--review-requested` | | レビューリクエスト保留中の PR のみ表示 |
| `--sort repository\|updated\|created` | | ソートキー（デフォルト: repository。--review-requested 時は updated） |
| `--reverse` | `-r` | 逆順でソート |
| `--no-cache` | | キャッシュを使用しない |

**使用例:**
```bash
./registry-manager pr-status --review-requested
./registry-manager pr-status --type thesis --sort updated -r
```

### edit コマンド

リポジトリの GitHub オーナーを編集します。

```bash
./registry-manager edit REPO_NAME [--add-owner USER | --remove-owner USER | --set-owners USER1,USER2]
```

### infer-student-id コマンド

github_username から名簿 CSV を元に学生 ID を推論して設定します。

```bash
./registry-manager infer-student-id REPO_NAME [--dry-run]
```

### propagate-workflow コマンド

ワークフロー更新をドラフトブランチ階層（main → 0th-draft → …）に伝播します。
draft ブランチ階層は学生リポジトリの PR ベースレビューの前提構造で、
詳細は [sotsuron-template](https://github.com/smkwlab/sotsuron-template) の
ドキュメントを参照してください。

```bash
./registry-manager propagate-workflow REPO_NAME
./registry-manager propagate-workflow --all [--type TYPE] [--from-template] [--dry-run]
```

### init コマンド

レジストリデータリポジトリを bootstrap します（private repo 作成・
`data/registry.json` と README の初期投入・config 生成。冪等）。
レジストリの**データ**ファイルは JSON（`data/registry.json`）です。
YAML なのはローカルの**設定**ファイル（`config.yml`）で、別物です。

```bash
./registry-manager init [OWNER/REPO] [--org ORG] [--force]
```

## 応用的な使用例

### 1. 定期的なステータス監視

```bash
#!/bin/bash
# 週次レポートスクリプト

echo "=== 週次リポジトリ状況レポート ==="
echo "日時: $(date)"
echo

echo "--- 全リポジトリ概要 ---"
./registry-manager list --format table --long

echo
echo "--- 卒論リポジトリ状況 ---"
./registry-manager list --type sotsuron --show-protection --long

echo
echo "--- CSV出力（Excel用） ---"
./registry-manager list --format csv --long > weekly_report.csv
echo "レポートを weekly_report.csv に保存しました"
```

### 2. バッチ処理での一括登録

```bash
#!/bin/bash
# 新年度学生リポジトリ一括登録

STUDENT_LIST="students.txt"  # k21rs001 k21rs002 ... の形式

while read -r STUDENT_ID; do
    echo "学生 $STUDENT_ID のリポジトリを登録中..."
    
    # WRリポジトリ
    ./registry-manager add "${STUDENT_ID}-wr" "$STUDENT_ID" wr
    
    # 卒論リポジトリ（4年生のみ）
    if [[ $STUDENT_ID =~ k[0-9]{2}rs ]]; then
        ./registry-manager add "${STUDENT_ID}-sotsuron" "$STUDENT_ID" sotsuron
    fi
    
    sleep 1  # API レート制限対策
done < "$STUDENT_LIST"
```

### 3. データエクスポートとバックアップ

```bash
#!/bin/bash
# データバックアップスクリプト

BACKUP_DIR="backup/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# JSON形式でフルバックアップ
./registry-manager list --format json --long > "$BACKUP_DIR/full_registry.json"

# CSV形式（Excel用）
./registry-manager list --format csv --long > "$BACKUP_DIR/registry_data.csv"

# タイプ別バックアップ
for TYPE in wr sotsuron ise-report; do
    ./registry-manager list --type "$TYPE" --format json --long > "$BACKUP_DIR/${TYPE}_repos.json"
done

echo "バックアップを $BACKUP_DIR に保存しました"
```

### 4. GitHubアクティビティ監視

```bash
#!/bin/bash
# 学生の活動状況チェック

echo "=== 最近のアクティビティ ==="

# 活動情報付きでリスト表示
./registry-manager list --activity --long --format table

echo
echo "=== 非アクティブリポジトリ（要確認） ==="

# JSONで取得して詳細分析
./registry-manager list --activity --format json --long | \
  jq -r '.[] | select(.last_commit_days_ago > 7) | "\(.repo_name): \(.last_commit_days_ago)日前"'
```

## トラブルシューティング

### よくある問題と解決方法

#### 1. GitHub API エラー

**問題:** `GitHub API request failed: rate limit exceeded`

**解決策:**
```bash
# APIトークンの設定確認
echo $GITHUB_TOKEN

# キャッシュの確認
./registry-manager cache status

# 必要に応じてキャッシュクリア
./registry-manager cache clear
```

#### 2. データ形式エラー

**問題:** `Invalid data format` や `JSON parsing error`

**解決策:**
```bash
# データ検証実行
./registry-manager validate

# 移行が必要かチェック
./registry-manager migrate status

# 移行実行（必要に応じて）
./registry-manager migrate dry-run
./registry-manager migrate execute
```

#### 3. 学生名が表示されない

**問題:** 学生IDが表示されるが名前が "Unknown" と表示される

**解決策:**
```bash
# 1. 名簿 CSV のパスを確認する
#    （config.yml の csv_path、または環境変数 REGISTRY_MANAGER_CSV_PATH。
#     どちらも未設定なら規約パス ~/.config/<github_org>/students.csv を参照し、
#     それも無ければ氏名解決は無効 = 名前が Unknown になる原因）
cat ~/.config/registry-manager/config.yml
echo "REGISTRY_MANAGER_CSV_PATH=$REGISTRY_MANAGER_CSV_PATH"

# 2. 確認したパスを代入して検査する
csv=/path/to/students.csv    # ← 上で確認した実際のパスに置き換える
ls -la "$csv"     # 存在確認
head -5 "$csv"    # 形式確認（UTF-8, カンマ区切り）
```

#### 4. パフォーマンス問題

**問題:** コマンド実行が遅い

**解決策:**
```bash
# キャッシュ状態確認
./registry-manager cache status

# API呼び出しを避けた基本的な表示
./registry-manager list --format table

# 必要に応じてキャッシュクリア
./registry-manager cache clear
```

### ログとデバッグ

#### デバッグモードの有効化

```bash
export REGISTRY_MANAGER_DEBUG=true
./registry-manager list --long
```

#### 詳細なエラー情報の取得

```bash
# Elixir実行での詳細ログ
mix run -e "RegistryManager.Commands.List.run([], [])"

# iExセッションでの対話的デバッグ
iex -S mix
iex> RegistryManager.GitHubAPI.get_repositories_json()
```

### 設定のトラブルシューティング

#### 設定値の確認

```bash
# 現在の設定確認
mix run -e "IO.inspect(Application.get_all_env(:registry_manager))"

# 特定設定値の確認
mix run -e "IO.puts(Application.get_env(:registry_manager, :organization))"
```

#### 権限問題

```bash
# 実行権限の確認
ls -la registry-manager

# 実行権限の付与
chmod +x registry-manager
```

### パフォーマンス最適化

#### 大量データでの最適化

```bash
# キャッシュを活用した効率的な処理
./registry-manager cache clear
./registry-manager list --long  # 初回はAPI呼び出し
./registry-manager list --long  # 2回目以降はキャッシュ利用

# 必要な情報のみ取得
./registry-manager list --no-names --format csv
```

## 参考情報

### 関連ドキュメント

- [API Reference](API_REFERENCE.md) - 詳細なAPI仕様
- [Configuration Guide](CONFIGURATION.md) - 設定の詳細
- [Development Guide](../README.md) - 開発者向けガイド

### サポート

問題が解決しない場合：

1. [GitHub Issues](https://github.com/smkwlab/thesis-student-registry/issues)
2. プロジェクトドキュメントの確認
3. 管理者への連絡