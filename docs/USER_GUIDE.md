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

#### 1. 基本設定（config/config.exs）

```elixir
config :registry_manager,
  # GitHub API設定
  github_token: System.get_env("GITHUB_TOKEN"),
  organization: "smkwlab",
  repository: "thesis-student-registry",
  file_path: "data/repositories.json",
  
  # キャッシュ設定
  cache_ttl: 300,  # 5分
  
  # 名簿 CSV（任意。氏名解決用。未設定時は ~/.config/<github_org>/students.csv を規約として参照）
  csv_path: "/path/to/students.csv"
```

#### 2. 環境変数の設定

```bash
# GitHub API トークンの設定（オプション）
export GITHUB_TOKEN="your_github_token_here"

# デバッグモード
export REGISTRY_MANAGER_DEBUG=true
```

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

### list コマンド

リポジトリ一覧を表示します。

```bash
./registry-manager list [TYPE] [OPTIONS]
```

**引数:**
- `TYPE` - フィルター対象のリポジトリタイプ（wr, sotsuron, ise-report）

**オプション:**

| オプション | 短縮形 | 説明 |
|------------|--------|------|
| `--long` | `-l` | 詳細情報を表示 |
| `--format FORMAT` | `-f` | 出力形式（table, csv, json） |
| `--type TYPE` | `-t` | リポジトリタイプでフィルター |
| `--show-type` | | タイプ情報を表示 |
| `--show-protection` | `-p` | 保護状態を表示 |
| `--show-student-id` | `-s` | 学生IDを表示 |
| `--no-names` | `-n` | 学生名を非表示 |
| `--activity` | `-a` | GitHub活動情報を表示 |
| `--owner-activity` | | オーナー活動情報を表示 |
| `--sort-by-time` | | 時間順でソート |
| `--reverse` | `-r` | 逆順でソート |

**使用例:**
```bash
# 卒論リポジトリのみ詳細表示
./registry-manager list --type sotsuron --long

# CSV形式で全データ出力
./registry-manager list --format csv --long

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
- `--force` - 既存エントリがある場合も強制実行

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
- `--force` - 確認なしで削除

**使用例:**
```bash
./registry-manager remove k21rs001-test
./registry-manager remove k21rs001-test --dry-run
```

### cache コマンド

キャッシュ管理を行います。

```bash
./registry-manager cache SUBCOMMAND [OPTIONS]
```

**サブコマンド:**
- `status` - キャッシュ状態の確認
- `clear` - キャッシュのクリア

**使用例:**
```bash
./registry-manager cache status
./registry-manager cache clear
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
#    （config.json の csv_path、または環境変数 REGISTRY_MANAGER_CSV_PATH。
#     どちらも未設定なら規約パス ~/.config/<github_org>/students.csv を参照し、
#     それも無ければ氏名解決は無効 = 名前が Unknown になる原因）
cat ~/.config/registry-manager/config.json
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