# Registry Manager v4 設定ガイド

Registry Manager v4の設定方法とカスタマイゼーションについて説明します。

## 目次

1. [設定概要](#設定概要)
2. [基本設定](#基本設定)
3. [環境変数](#環境変数)
4. [高度な設定](#高度な設定)
5. [環境別設定](#環境別設定)
6. [トラブルシューティング](#トラブルシューティング)

## 設定概要

Registry Manager v4は以下の優先順位で設定を読み込みます：

1. **環境変数** - 最高優先度
2. **設定ファイル** - `config/config.exs`
3. **デフォルト値** - ハードコーディングされた値

### 設定の確認方法

```bash
# 現在の全設定を確認
mix run -e "IO.inspect(Application.get_all_env(:registry_manager))"

# 特定の設定値を確認
mix run -e "IO.puts(Application.get_env(:registry_manager, :organization, \"未設定\"))"
```

## 基本設定

### config/config.exs

```elixir
import Config

config :registry_manager,
  # GitHub API 設定
  github_token: System.get_env("GITHUB_TOKEN"),
  organization: "smkwlab",
  repository: "thesis-student-registry",
  file_path: "data/repositories.json",
  
  # キャッシュ設定
  cache_ttl: 300,  # 秒単位（5分）
  cache_dir: System.tmp_dir() |> Path.join("registry_manager_cache"),
  
  # データファイル設定
  csv_file_path: "smkwlab.csv",
  backup_enabled: true,
  backup_count: 5,
  
  # 表示設定
  default_format: "table",
  show_colors: true,
  timezone: "Asia/Tokyo",
  
  # パフォーマンス設定
  api_timeout: 30_000,  # ミリ秒
  concurrent_requests: 5,
  retry_attempts: 3,
  retry_delay: 1000,    # ミリ秒
  
  # ログ設定
  log_level: :info,
  debug_mode: false
```

### 設定項目の説明

#### GitHub API設定

| 項目 | デフォルト値 | 説明 |
|------|-------------|------|
| `github_token` | `nil` | GitHub API アクセストークン |
| `organization` | `"smkwlab"` | GitHub組織名 |
| `repository` | `"thesis-student-registry"` | データリポジトリ名 |
| `file_path` | `"data/repositories.json"` | レジストリデータファイルパス |

#### キャッシュ設定

| 項目 | デフォルト値 | 説明 |
|------|-------------|------|
| `cache_ttl` | `300` | キャッシュ有効期間（秒） |
| `cache_dir` | `{tmp}/registry_manager_cache` | キャッシュディレクトリ |

#### データファイル設定

| 項目 | デフォルト値 | 説明 |
|------|-------------|------|
| `csv_file_path` | `"smkwlab.csv"` | 学生データCSVファイル |
| `backup_enabled` | `true` | 自動バックアップの有効化 |
| `backup_count` | `5` | 保持するバックアップ数 |

#### 表示設定

| 項目 | デフォルト値 | 説明 |
|------|-------------|------|
| `default_format` | `"table"` | デフォルト出力形式 |
| `show_colors` | `true` | カラー出力の有効化 |
| `timezone` | `"Asia/Tokyo"` | 表示用タイムゾーン |

#### パフォーマンス設定

| 項目 | デフォルト値 | 説明 |
|------|-------------|------|
| `api_timeout` | `30000` | API タイムアウト（ミリ秒） |
| `concurrent_requests` | `5` | 同時リクエスト数 |
| `retry_attempts` | `3` | リトライ回数 |
| `retry_delay` | `1000` | リトライ間隔（ミリ秒） |

## 環境変数

### 重要な環境変数

```bash
# GitHub API アクセストークン（必須）
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

# 組織名のオーバーライド
export REGISTRY_MANAGER_ORGANIZATION="custom-org"

# リポジトリ名のオーバーライド
export REGISTRY_MANAGER_REPOSITORY="custom-repo"

# デバッグモード
export REGISTRY_MANAGER_DEBUG="true"

# キャッシュTTL（秒）
export REGISTRY_MANAGER_CACHE_TTL="600"

# ログレベル
export REGISTRY_MANAGER_LOG_LEVEL="debug"
```

### 環境変数の設定方法

#### 1. シェル設定ファイル（永続的）

```bash
# ~/.bashrc または ~/.zshrc に追加
echo 'export GITHUB_TOKEN="your_token_here"' >> ~/.bashrc
source ~/.bashrc
```

#### 2. 実行時指定（一時的）

```bash
GITHUB_TOKEN="your_token" ./registry-manager list
```

#### 3. .envファイル（開発環境）

```bash
# .env ファイルを作成
cat > .env << EOF
GITHUB_TOKEN=your_token_here
REGISTRY_MANAGER_DEBUG=true
REGISTRY_MANAGER_CACHE_TTL=600
EOF

# 環境変数として読み込み
export $(cat .env | xargs)
```

## 高度な設定

### 1. 複数環境での設定管理

#### config/dev.exs (開発環境)

```elixir
import Config

config :registry_manager,
  debug_mode: true,
  log_level: :debug,
  cache_ttl: 60,  # 短いキャッシュ
  api_timeout: 10_000,
  show_colors: true,
  backup_enabled: false  # 開発時はバックアップ無効
```

#### config/prod.exs (本番環境)

```elixir
import Config

config :registry_manager,
  debug_mode: false,
  log_level: :info,
  cache_ttl: 300,
  api_timeout: 30_000,
  backup_enabled: true,
  backup_count: 10  # 本番では多めにバックアップ
```

#### config/test.exs (テスト環境)

```elixir
import Config

config :registry_manager,
  env: :test,
  debug_mode: false,
  log_level: :warning,
  github_token: "test_token",
  organization: "test-org",
  repository: "test-repo",
  cache_ttl: 0,  # キャッシュ無効
  backup_enabled: false
```

### 2. カスタムキャッシュディレクトリ

```elixir
config :registry_manager,
  cache_dir: case System.get_env("HOME") do
    nil -> System.tmp_dir() |> Path.join("registry_manager_cache")
    home -> Path.join([home, ".cache", "registry_manager"])
  end
```

### 3. プロキシ設定

```elixir
config :registry_manager,
  # HTTPクライアント設定
  http_options: [
    proxy: {:http, "proxy.example.com", 8080, []},
    timeout: 30_000,
    recv_timeout: 30_000
  ]
```

### 4. ログ設定のカスタマイズ

```elixir
config :logger,
  level: :info,
  backends: [:console, {LoggerFileBackend, :file_log}]

config :logger, :file_log,
  path: "logs/registry_manager.log",
  level: :debug,
  format: "$date $time [$level] $metadata$message\n"
```

## 環境別設定

### 開発環境 (MIX_ENV=dev)

```bash
# 設定例
export MIX_ENV=dev
export REGISTRY_MANAGER_DEBUG=true
export REGISTRY_MANAGER_CACHE_TTL=60
export REGISTRY_MANAGER_LOG_LEVEL=debug

# 実行
mix run -e "RegistryManager.CLI.main([\"list\", \"--long\"])"
```

**特徴:**
- デバッグ情報の詳細表示
- 短いキャッシュ時間
- カラー出力有効
- バックアップ無効

### 本番環境 (MIX_ENV=prod)

```bash
# 設定例
export MIX_ENV=prod
export GITHUB_TOKEN="production_token"
export REGISTRY_MANAGER_CACHE_TTL=300
export REGISTRY_MANAGER_LOG_LEVEL=info

# ビルドと実行
mix deps.get --only prod
MIX_ENV=prod mix escript.build
./registry-manager list
```

**特徴:**
- 最適化されたパフォーマンス
- 本番用GitHub トークン
- 自動バックアップ有効
- エラーログのみ

### テスト環境 (MIX_ENV=test)

```bash
# テスト実行
MIX_ENV=test mix test
```

**特徴:**
- モックされたGitHub API
- キャッシュ無効
- テスト用データ
- バックアップ無効

## セキュリティ設定

### 1. GitHub トークンの安全な管理

```bash
# 権限を制限したファイルに保存
echo "GITHUB_TOKEN=your_token" > ~/.registry_manager_token
chmod 600 ~/.registry_manager_token

# 使用時に読み込み
source ~/.registry_manager_token
./registry-manager list
```

### 2. 組織アクセス制限

```elixir
config :registry_manager,
  # 許可された組織のみ
  allowed_organizations: ["smkwlab", "ksu-research"],
  
  # アクセス制御
  require_token: true,
  
  # IP制限（本番環境のみ）
  allowed_ips: ["192.168.1.0/24", "10.0.0.0/8"]
```

## パフォーマンス調整

### 1. キャッシュ最適化

```elixir
config :registry_manager,
  # アクセスパターンに応じてTTL調整
  cache_ttl: case Mix.env() do
    :dev -> 60      # 開発時は短く
    :test -> 0      # テスト時は無効
    :prod -> 300    # 本番は5分
  end,
  
  # メモリ使用量制限
  cache_max_size: 100,  # エントリ数
  cache_memory_limit: 50_000_000  # 50MB
```

### 2. API レート制限対応

```elixir
config :registry_manager,
  # 並行リクエスト制限
  concurrent_requests: 3,
  
  # リクエスト間隔
  request_interval: 200,  # ミリ秒
  
  # バックオフ戦略
  backoff_strategy: :exponential,
  max_backoff: 60_000  # 1分
```

### 3. 大量データ対応

```elixir
config :registry_manager,
  # バッチサイズ
  batch_size: 50,
  
  # ストリーミング処理
  use_streaming: true,
  
  # メモリ制限
  memory_limit: 100_000_000  # 100MB
```

## トラブルシューティング

### 設定関連の問題

#### 1. 設定が反映されない

```bash
# 設定の確認
mix run -e "IO.inspect(Application.get_all_env(:registry_manager))"

# 環境変数の確認
env | grep REGISTRY_MANAGER

# キャッシュクリア
rm -rf ~/.cache/registry_manager
```

#### 2. GitHub API エラー

```bash
# トークンの確認
echo $GITHUB_TOKEN | cut -c1-10  # 最初の10文字のみ表示

# 組織アクセス権の確認
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/orgs/smkwlab/repos

# APIレート制限の確認
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/rate_limit
```

#### 3. パフォーマンス問題

```bash
# キャッシュ状態の確認
./registry-manager cache status

# メモリ使用量の監視
mix run -e "IO.puts(:erlang.memory(:total))"

# プロファイリング
mix profile.fprof -e "RegistryManager.Commands.List.run([], [])"
```

### 設定のバリデーション

```elixir
# config/config.exs に追加
config :registry_manager,
  validate_config: true

# バリデーション関数
defmodule RegistryManager.ConfigValidator do
  def validate! do
    required_configs = [:organization, :repository, :file_path]
    
    Enum.each(required_configs, fn key ->
      case Application.get_env(:registry_manager, key) do
        nil -> raise "Missing required config: #{key}"
        "" -> raise "Empty config value: #{key}"
        _ -> :ok
      end
    end)
    
    :ok
  end
end
```

### 設定のリセット

```bash
# 全キャッシュクリア
rm -rf ~/.cache/registry_manager
rm -rf /tmp/registry_manager_cache

# 環境変数クリア
unset GITHUB_TOKEN
unset REGISTRY_MANAGER_DEBUG
unset REGISTRY_MANAGER_CACHE_TTL

# デフォルト設定での実行
./registry-manager list
```

## 参考情報

### 関連ドキュメント

- [User Guide](USER_GUIDE.md) - 基本的な使用方法
- [API Reference](API_REFERENCE.md) - API仕様
- [Development Guide](../README.md) - 開発者向けガイド

### 外部リンク

- [Elixir Config Documentation](https://hexdocs.pm/elixir/Config.html)
- [GitHub API Documentation](https://docs.github.com/en/rest)
- [Mix Environment](https://hexdocs.pm/mix/Mix.html#env/0)