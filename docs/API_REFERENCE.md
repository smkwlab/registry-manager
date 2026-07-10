# Registry Manager v4 API Reference

学生リポジトリレジストリ管理システムのAPI仕様書です。

## 概要

Registry Manager v4は、九州産業大学の論文執筆支援システムにおけるリポジトリ管理のためのElixirベースのCLIツールです。学生リポジトリの登録・管理・監視機能を提供します。

## アーキテクチャ

```
RegistryManager
├── CLI             # コマンドライン解析
├── Config          # 設定管理
├── GitHubAPI       # GitHub API統合
├── Repository      # リポジトリ操作
├── Validation      # データ検証
├── TimestampManager # タイムスタンプ管理
├── Migration       # データ移行
└── Commands/       # コマンド実装
    ├── List        # リスト表示
    ├── Cache       # キャッシュ管理
    └── Migrate     # データ移行
```

## モジュール詳細

### RegistryManager.CLI

コマンドライン引数の解析とルーティングを担当します。

#### 主要関数

```elixir
@spec main([String.t()]) :: :ok
def main(args)
```
CLIアプリケーションのエントリーポイント。引数を解析してコマンドを実行します。

```elixir
@spec parse_args([String.t()]) :: command_result()
def parse_args(args)
```
コマンドライン引数を解析し、実行するコマンドとオプションを返します。

**戻り値:**
- `{:list, type, opts}` - リスト表示コマンド
- `{:add, repo_name, opts}` - リポジトリ追加コマンド
- `{:update, repo_name, field, value, opts}` - 更新コマンド
- `:help` - ヘルプ表示

### RegistryManager.Repository

リポジトリデータの管理と操作を担当します。

#### 主要関数

```elixir
@spec add(String.t(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
def add(repo_name, student_id, repo_type, opts \\ [])
```
新しいリポジトリをレジストリに追加します。

**引数:**
- `repo_name` - リポジトリ名（例: "k21rs001-sotsuron"）
- `student_id` - 学生ID（例: "k21rs001"）
- `repo_type` - リポジトリタイプ（"sotsuron", "wr", "ise-report"）
- `opts` - オプション（dry_run: boolean など）

```elixir
@spec add_with_inference(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
def add_with_inference(repo_name, opts \\ [])
```
リポジトリ名から学生IDとタイプを推論してリポジトリを追加します。

```elixir
@spec update(String.t(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
def update(repo_name, field, value, opts \\ [])
```
既存リポジトリの特定フィールドを更新します。

```elixir
@spec remove(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
def remove(repo_name, opts \\ [])
```
リポジトリをレジストリから削除します。

```elixir
@spec mark_protected(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
def mark_protected(repo_name, opts \\ [])
```
リポジトリのブランチ保護状態をマークします。

### RegistryManager.Commands.List

リポジトリ一覧表示機能を提供します。

#### 主要関数

```elixir
@spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
def run(args, opts)
```
リポジトリ一覧を表示します。

**オプション:**
- `format: "table" | "csv" | "json"` - 出力形式
- `type: String.t()` - フィルター対象のリポジトリタイプ
- `long: boolean()` - 詳細情報表示
- `show_type: boolean()` - タイプ情報表示
- `show_protection: boolean()` - 保護状態表示
- `activity: boolean()` - 活動情報表示
- `sort: "name" | "time"` - ソートキー（CLI の `-t` は `"time"` の短縮）

### RegistryManager.GitHubAPI

GitHub APIとの統合機能を提供します。

#### 主要関数

```elixir
@spec get_repositories_json() :: {:ok, {map(), String.t()}} | {:error, String.t()}
def get_repositories_json()
```
GitHub APIからリポジトリデータを取得します。キャッシュされたデータがあれば利用します。

**戻り値:**
- `{:ok, {data, sha}}` - データとSHA値
- `{:error, reason}` - エラーメッセージ

```elixir
@spec update_repositories_json(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
def update_repositories_json(data, message)
```
レジストリデータをGitHub APIで更新します。

```elixir
@spec get_activity_info(String.t()) :: {:ok, map()} | {:error, String.t()}
def get_activity_info(repo_name)
```
指定されたリポジトリの活動情報を取得します。

### RegistryManager.Validation

データ検証機能を提供します。

#### 主要関数

```elixir
@spec validate_student_id(String.t()) :: :ok | {:error, String.t()}
def validate_student_id(student_id)
```
学生IDの形式を検証します。

**有効形式:**
- 学部生: `k##rs###` または `k##jk###`（例: k21rs001, k92jk123）
- 大学院生: `k##gjk##`（例: k91gjk01, k92gjk15）

```elixir
@spec validate_repository_entry(map()) :: :ok | {:error, String.t()}
def validate_repository_entry(entry)
```
リポジトリエントリのv4データ構造を検証します。

**必須フィールド（v4）:**
- `student_id` - 学生ID
- `repository_type` - リポジトリタイプ
- `repository_created_at` - リポジトリ作成日時
- `registry_created_at` - レジストリ登録日時
- `registry_updated_at` - 最終更新日時

### RegistryManager.TimestampManager

タイムスタンプ管理機能を提供します。

#### 主要関数

```elixir
@spec current_utc_time() :: DateTime.t()
def current_utc_time()
```
現在のUTC時刻を取得します。

```elixir
@spec format_for_display(DateTime.t()) :: String.t()
def format_for_display(datetime)
```
DateTimeをJST表示用にフォーマットします。

```elixir
@spec create_registry_timestamps(String.t() | nil) :: map()
def create_registry_timestamps(github_created_at)
```
新規エントリ用の3つのタイムスタンプフィールドを作成します。

```elixir
@spec migrate_legacy_timestamps(map()) :: map()
def migrate_legacy_timestamps(data)
```
レガシー形式のタイムスタンプを新形式に移行します。

### RegistryManager.Migration

v1からv4へのデータ移行機能を提供します。

#### 主要関数

```elixir
@spec dry_run_migration(map()) :: {:ok, map()} | {:error, String.t()}
def dry_run_migration(registry_data)
```
移行処理のドライランを実行し、レポートを生成します。

```elixir
@spec migrate_to_v4(map()) :: {:ok, {map(), map()}} | {:error, String.t()}
def migrate_to_v4(registry_data)
```
実際のv4形式への移行を実行します。

```elixir
@spec is_v4_format?(map()) :: boolean()
def is_v4_format?(repo_info)
```
エントリがv4形式かどうかを判定します。

## データ形式

### v4レジストリエントリ

```elixir
%{
  "student_id" => "k21rs001",
  "repository_type" => "sotsuron",
  "repository_created_at" => "2025-07-08T06:51:39.835808Z",
  "registry_created_at" => "2025-07-08T06:51:39.835808Z", 
  "registry_updated_at" => "2025-07-08T06:51:39.835808Z",
  "github_username" => "student001",  # オプション
  "protection_status" => "protected"  # オプション
}
```

### 設定項目

```elixir
# config/config.exs
config :registry_manager,
  cache_ttl: 300,           # キャッシュTTL（秒）
  github_token: nil,        # GitHub API トークン
  organization: "smkwlab",  # GitHub組織名
  repository: "thesis-student-registry", # リポジトリ名
  file_path: "data/repositories.json"    # データファイルパス
```

## エラー処理

各関数は統一されたエラー形式を返します：

```elixir
{:ok, result}           # 成功
{:error, "reason"}      # エラー（日本語メッセージ）
```

## 使用例

### 基本的な使用方法

```elixir
# リポジトリ追加
{:ok, message} = RegistryManager.Repository.add("k21rs001-sotsuron", "k21rs001", "sotsuron")

# リスト表示
{:ok, output} = RegistryManager.Commands.List.run([], format: "json", long: true)

# データ検証
:ok = RegistryManager.Validation.validate_student_id("k21rs001")

# 移行チェック
{:ok, report} = RegistryManager.Migration.dry_run_migration(data)
```

### CLIでの使用

```bash
# 基本的なリスト表示
./registry-manager list

# 詳細なJSON出力
./registry-manager list --format json --long

# 特定タイプのフィルタリング
./registry-manager list --type sotsuron --show-protection

# リポジトリ追加
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron

# データ移行
./registry-manager migrate status
./registry-manager migrate dry-run
./registry-manager migrate execute
```

## パフォーマンス特性

- **キャッシュ**: GitHub API応答を最大5分間キャッシュ
- **並行処理**: 複数のリスト操作が同時実行可能
- **メモリ効率**: 大量データ（100エントリ以上）でも1秒以内で処理
- **API制限**: GitHub APIレート制限に対応した適切な間隔

## セキュリティ

- **データ分離**: 学生の個人情報はCSVファイルで別管理
- **アトミック操作**: GitHub API経由での整合性保証
- **入力検証**: 全入力データの厳密な検証
- **アクセス制御**: GitHub組織レベルでのアクセス管理